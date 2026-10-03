#!/usr/bin/env python3
"""Scoped Home reads revalidate identity before admitting foreign decisions.

Fixture PTY evidence only. HTTP callbacks prove scoped reads, their exact
identity, and absence of a full tick; this does not establish owner execution.
"""
import copy
import json
import os
from pathlib import Path
import re
import sys
import threading

import test_tui_home_decision_cards_pty as cards
import test_tui_home_journey_pty as home
import test_tui_keyboard_input as h


BRIEFING = "/api/v1/dashboard/briefing"


def scoped_identity_journey(executable, *, unread):
    fixtures = cards.fixtures_with_held([])
    requests = []
    lock = threading.Lock()
    calls = []
    state = {"changed": False}
    label = b"scoped-unread-operator" if unread else b"scoped-foreign-question"
    ask = copy.deepcopy(h.keeper_asks_response())
    ask[1]["asks"][0].update(ask_id=label.decode(), context=label.decode())
    empty_asks = copy.deepcopy(ask)
    empty_asks[1].update(asks=[], open_count=0)
    _fixtures, items, _new = h.approval_selection_http_fixtures()
    operator = h.approval_selection_snapshot([
        dict(items[0], confirm_token=label.decode(),
             payload={"reason": label.decode()})
    ])

    def track(path, resolve):
        def reading():
            with lock:
                response = resolve()
                calls.append((path, state["changed"], response))
                return response
        return reading

    briefing = fixtures[BRIEFING]
    fixtures[BRIEFING] = track(BRIEFING, lambda: briefing)
    def asks_reading():
        response = copy.deepcopy(ask if state["changed"] and not unread else empty_asks)
        if state["changed"]:
            state["decision_read"] = True
        return response

    fixtures[h.KEEPER_ASKS_PATH] = track(h.KEEPER_ASKS_PATH, asks_reading)
    fixtures[cards.OPERATOR_PATH] = track(
        cards.OPERATOR_PATH,
        lambda: operator if state["changed"] and unread
        else h.approval_selection_snapshot([]),
    )
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])

    def prepare(base):
        home.seed_goals(base)
        config = Path(base, ".masc", "config")
        config.mkdir(parents=True, exist_ok=True)
        (config / "runtime.toml").write_text(
            '[tui]\nopening = "keeper"\nopening_keeper = "alpha"\n'
            'last_chat_keeper = "alpha"\n',
            encoding="utf-8",
        )
        local = Path(base).resolve()
        foreign = local / "foreign-server-B"
        (foreign / ".masc").mkdir(parents=True)
        state.update(local=str(local), foreign=str(foreign))

        def health():
            if state["changed"] and unread:
                return h.RawHttpResponse(503, b'{"error":"scoped identity unavailable"}',
                                         content_type="application/json")
            root = foreign if state["changed"] and state.get("decision_read") else local
            payload = {
                "status": "ok", "paths": {
                    "cwd": str(root), "effective_base_path": str(root),
                    "effective_masc_root": str(root / ".masc"),
                    "effective_has_masc_dir": True,
                },
            }
            # Tuple health responses are rewritten to A by the shared handler.
            return h.RawHttpResponse(200, json.dumps(payload).encode(),
                                     content_type="application/json")

        for path in ("/health", "/health?full=1"):
            fixtures[path] = track(path, health)

    def snapshot():
        with lock:
            return list(calls)

    def assert_scoped(baseline):
        readings = snapshot()
        assert sum(path == BRIEFING for path, _, _ in readings) == baseline, (
            "a full refresh confounded the scoped regression", readings
        )
        changed = [(path, response) for path, switched, response in readings if switched]
        health_reads = [response for path, response in changed if path == "/health"]
        assert health_reads, "Home scoped delta never re-read compact /health"
        for response in health_reads:
            assert response.status == (503 if unread else 200)
        if not unread:
            roots = [json.loads(response.body)["paths"] for response in health_reads]
            assert roots[0]["effective_base_path"] == state["local"], roots
            assert roots[-1]["effective_base_path"] == state["foreign"], roots
            assert roots[-1]["effective_masc_root"] == state["foreign"] + "/.masc", roots
        # Health must precede the newly fetched decision source, not merely
        # happen eventually after foreign rows have already become actionable.
        decision_path = cards.OPERATOR_PATH if unread else h.KEEPER_ASKS_PATH
        if unread:
            assert not any(path == decision_path for path, _ in changed), changed
            home.assert_no_decision_posts(requests)
            return
        assert any(path == decision_path for path, _ in changed), changed
        assert next(i for i, (path, _) in enumerate(changed) if path == "/health") < next(
            i for i, (path, _) in enumerate(changed) if path == decision_path
        ), changed
        home.assert_no_decision_posts(requests)

    def interact(process, fd, _slave, output, base):
        # Saved startup opens this chat only after a matching full refresh.
        # The chat footer has no HTTP badge; assert the captured A health and
        # briefing readings below rather than waiting for an absent label.
        h.wait_for_output(process, fd, output, b"Esc:list", start=0, timeout=10)
        # The first boot read establishes authority and schedules one matching
        # full follow-up. Settle it before attributing reads to Home navigation.
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: sum(path == BRIEFING for path, _, _ in snapshot()) >= 2,
            timeout=10), snapshot()
        h.drain_until_quiet(process, fd, output)
        initial = snapshot()
        local_reads = [response for path, _, response in initial if path == "/health"]
        assert local_reads and all(
            json.loads(response.body)["paths"]["effective_base_path"]
            == str(Path(base).resolve()) for response in local_reads
        ), "initial full refresh did not read matching A"
        baseline = sum(path == BRIEFING for path, _, _ in initial)
        assert baseline >= 1, "initial full refresh never read briefing"
        # Saved opening resolves after the initial full identity read. That
        # boot read may include Home sources; the settled surface is chat,
        # whose needs exclude decisions. Returning to Home must fetch them
        # again, and the changed-call ledger distinguishes those new reads.
        assert b"chat" in h.screen_text(bytes(output)), "initial chat was not applied"
        with lock:
            state["changed"] = True
        start = len(output)
        h.press_label_on_screen(process, fd, output, b"Dashboard", row=1, needle=b"Enter:open")
        identity = b"workspace identity not read"
        h.wait_for_output(process, fd, output, identity, start=start, timeout=10)
        assert_scoped(baseline)
        frame = h.resize_and_wait(process, fd, output, rows=40, columns=160,
                                  needle=b"Enter:open", final_cursor=b"\x1b[?25l")
        visible = h.screen_text(frame)
        assert label not in visible, ("unverified decision was cached", visible)
        assert b"not fully read" in visible, visible
        home.assert_no_decision_posts(requests)
        assert_scoped(baseline)
        os.write(fd, b"q")
        state["baseline"] = baseline

    h.run_terminal_scenario(
        executable,
        description="Home scoped identity " + ("503 refuses operator confirmation" if unread
                                               else "A/B mixed read discards foreign decision"),
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare, refresh=60.0, starts_in_chat=True,
    )
    assert_scoped(state["baseline"])


def superseded_scoped_match_journey(executable):
    """An A scoped bundle released after a full B bundle cannot restore A."""
    fixtures = cards.fixtures_with_held([])
    requests = []
    lock = threading.Lock()
    calls = []
    state = {"phase": "initial"}
    old_label = b"superseded-A-question"
    new_label = b"newer-B-question"

    def question(label):
        response = copy.deepcopy(h.keeper_asks_response())
        response[1]["asks"][0].update(ask_id=label.decode(), context=label.decode())
        return response

    old_response = question(old_label)
    new_response = question(new_label)
    empty_response = copy.deepcopy(old_response)
    empty_response[1].update(asks=[], open_count=0)
    _fixtures, items, _new = h.approval_selection_http_fixtures()
    old_operator_label = b"superseded-A-operator"
    new_operator_label = b"newer-B-operator"

    def operator(label):
        return h.approval_selection_snapshot([
            dict(items[0], confirm_token=label.decode(),
                 payload={"reason": label.decode()})
        ])

    gate = h.GatedHttpResponse(operator(old_operator_label), hold_seconds=30.0)
    newer_operator_read = threading.Event()
    newer_asks_read = threading.Event()
    released_asks_read = threading.Event()
    briefing = fixtures[BRIEFING]
    initial_briefing = copy.deepcopy(briefing)
    initial_briefing[1]["summary"]["workspace_health"] = "initializing"

    def record(path):
        with lock:
            phase = state["phase"]
            calls.append((path, phase))
            return phase

    def read_briefing():
        with lock:
            phase = state["phase"]
            calls.append((BRIEFING, phase))
            initial_read = phase == "initial" and calls.count((BRIEFING, "initial")) == 1
        if initial_read:
            return initial_briefing
        return briefing

    def read_operator():
        with lock:
            phase = state["phase"]
            calls.append((cards.OPERATOR_PATH, phase))
            block = phase == "old-scoped" and not state.get("gate_claimed", False)
            if block:
                state["gate_claimed"] = True
        if block:
            # Only the first scoped GET waits. Full B requests this same
            # endpoint while it is held and must complete independently.
            return gate()
        if phase == "new-full":
            assert gate.requested.is_set(), "newer full read did not overlap old scoped GET"
            assert not gate.completed.is_set(), "old scoped GET completed before full B"
            newer_operator_read.set()
            return operator(new_operator_label)
        return h.approval_selection_snapshot([])

    def read_asks():
        phase = record(h.KEEPER_ASKS_PATH)
        if phase == "new-full":
            newer_asks_read.set()
            return new_response
        if phase == "released":
            released_asks_read.set()
            return old_response
        if phase == "old-scoped":
            return old_response
        return empty_response

    fixtures[BRIEFING] = read_briefing
    fixtures[cards.OPERATOR_PATH] = read_operator
    fixtures[h.KEEPER_ASKS_PATH] = read_asks
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])

    def prepare(base):
        home.seed_goals(base)
        config = Path(base, ".masc", "config")
        config.mkdir(parents=True, exist_ok=True)
        (config / "runtime.toml").write_text(
            '[tui]\nopening = "keeper"\nopening_keeper = "alpha"\n'
            'last_chat_keeper = "alpha"\n', encoding="utf-8",
        )
        local = Path(base).resolve()
        foreign = local / "newer-full-server-B"
        (foreign / ".masc").mkdir(parents=True)
        state.update(local=str(local), foreign=str(foreign))

        def health(path):
            phase = record(path)
            root = foreign if phase in ("new-full", "released") else local
            return h.RawHttpResponse(200, json.dumps({
                "status": "ok", "paths": {
                    "cwd": str(root), "effective_base_path": str(root),
                    "effective_masc_root": str(root / ".masc"),
                    "effective_has_masc_dir": True,
                },
            }).encode(), content_type="application/json")

        fixtures["/health"] = lambda: health("/health")
        fixtures["/health?full=1"] = lambda: health("/health?full=1")

    def interact(process, fd, _slave, output, _base):
        try:
            h.wait_for_output(process, fd, output, b"Esc:list", start=0, timeout=10)
            h.resize_and_wait(process, fd, output, rows=40, columns=159, needle=b"Esc:list")
            # Initial authority adoption schedules a second full reading while
            # the connection badge stays connected. Its distinct Health row
            # proves that bundle applied before the scoped-only baseline.
            h.press_label_on_screen(process, fd, output, b"Dashboard",
                                    row=1, needle=b"Enter:open")
            h.wait_for_output(process, fd, output, b"Health: ok", start=0, timeout=10)
            h.palette_go(process, fd, output, b"keeper alpha", b"Esc:list")
            h.drain_until_quiet(process, fd, output)
            with lock:
                assert ("/health", "initial") in calls, calls
                baseline = calls.count((BRIEFING, "initial"))
                assert baseline >= 2, calls
                state["phase"] = "old-scoped"
            # Home's static footer is available before its scoped GET settles.
            h.press_label_on_screen(process, fd, output, b"Dashboard",
                                    row=1, needle=b"Enter:open")
            assert h.wait_for_fixture_event(process, fd, output, gate.requested, timeout=10), (
                "old scoped decision GET never reached the response gate"
            )
            with lock:
                assert ("/health", "old-scoped") in calls, calls
                assert calls.index(("/health", "old-scoped")) < calls.index(
                    (cards.OPERATOR_PATH, "old-scoped")
                ), calls
                assert sum(path == BRIEFING for path, _ in calls) == baseline, calls
                state["phase"] = "new-full"
            assert not gate.release.is_set() and not gate.completed.is_set()
            start = len(output)
            os.write(fd, b"r")
            assert h.wait_for_fixture_event(process, fd, output, newer_operator_read, timeout=10), (
                "new full refresh did not pass the held scoped operator GET"
            )
            assert h.wait_for_fixture_event(process, fd, output, newer_asks_read, timeout=10), (
                "explicit full refresh failed to overtake the pending scoped GET"
            )
            h.wait_for_output(process, fd, output, b"[workspace mismatch]",
                              start=start, timeout=10)
            replacement = h.resize_and_wait(
                process, fd, output, rows=40, columns=160,
                needle=b"Enter:open", controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            visible = h.screen_text(replacement)
            assert b"[workspace mismatch]" in visible, visible
            assert b"not fully read" in visible, visible
            assert all(label not in visible for label in
                       (old_label, old_operator_label, new_label, new_operator_label)), visible
            assert not gate.completed.is_set(), "mismatch was not applied before old completion"
            assert gate.calls == 1, "more than the first scoped decision GET was gated"
            with lock:
                new_full_reads = calls.count((BRIEFING, "new-full"))
                assert new_full_reads >= 1, calls
                assert ("/health", "new-full") in calls, calls
                assert calls.count((cards.OPERATOR_PATH, "new-full")) == new_full_reads, calls
                # A timed-out old operator GET must not masquerade as the
                # new full asks GET before the held response is released.
                assert calls.count((h.KEEPER_ASKS_PATH, "new-full")) == new_full_reads, calls
                assert calls.index(("/health", "old-scoped")) < calls.index(
                    ("/health", "new-full")
                ) < calls.index((h.KEEPER_ASKS_PATH, "new-full")), calls
                state["phase"] = "released"
            gate.release.set()
            assert h.wait_for_fixture_event(process, fd, output, gate.completed, timeout=10), (
                "old scoped GET never completed after release"
            )
            assert h.wait_for_fixture_event(
                process, fd, output, released_asks_read, timeout=10
            ), "old scoped reader never consumed its released operator response"
            # Consume the returned response and mailbox, then force a fresh
            # frame: accumulated pre-release mismatch bytes are not evidence.
            h.drain_until_quiet(process, fd, output, cap=1)
            drawn = h.resize_and_wait(
                process, fd, output, rows=40, columns=161,
                needle=b"Enter:open", controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            visible = h.screen_text(drawn)
            assert b"[workspace mismatch]" in visible, "old scoped A restored authority"
            assert all(label not in visible for label in
                       (old_label, old_operator_label, new_label, new_operator_label)), (
                "unverified full or superseded scoped decisions were restored", visible)
            with lock:
                # The old read now performs one post-read identity probe;
                # no extra full refresh can repair a wrongly admitted bundle.
                assert sum(path == BRIEFING for path, _ in calls) == baseline + new_full_reads, calls
                assert calls.count(("/health", "released")) == 1, calls
            home.assert_no_decision_posts(requests)
            os.write(fd, b"q")
        finally:
            gate.release.set()

    h.run_terminal_scenario(
        executable, description="Home drops old scoped A after newer full B mismatch",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare, refresh=60.0, starts_in_chat=True,
    )
    home.assert_no_decision_posts(requests)


def gate_before_identity_refresh_journey(executable):
    """A B Gate body is rejected before the ordinary identity refresh sees B."""
    fixtures = cards.fixtures_with_held([])
    requests = []
    lock = threading.Lock()
    calls = []
    state = {"phase": "A", "hold_gate": False}
    initial = copy.deepcopy(h.blocked_gate_detail_http_fixtures()[cards.GATE_PATH])
    initial[1]["approval_queue"] = []
    # With no cached lane modes the Approvals surface prints the exact Gate
    # error instead of retaining the older lane labels over it.
    initial[1]["hitl"] = None
    late = copy.deepcopy(initial)
    late[1]["approval_queue"] = copy.deepcopy(
        h.blocked_gate_detail_http_fixtures()[cards.GATE_PATH][1]["approval_queue"])
    late[1]["approval_queue"][0]["id"] = "foreign-gate-before-identity"
    held_gate = h.GatedHttpResponse(late, hold_seconds=30.0)
    initial_gate_read = threading.Event()
    briefing = fixtures[BRIEFING]

    def record(path):
        with lock:
            calls.append((path, state["phase"]))

    def gate():
        record(cards.GATE_PATH)
        if state["hold_gate"]:
            return held_gate()
        initial_gate_read.set()
        return initial

    def read_briefing():
        record(BRIEFING)
        return briefing

    fixtures[cards.GATE_PATH] = gate
    fixtures[BRIEFING] = read_briefing

    def prepare(base):
        home.seed_goals(base)
        local = Path(base).resolve()
        foreign = local / "gate-before-identity-B"
        (foreign / ".masc").mkdir(parents=True)

        def health():
            record("/health")
            root = foreign if state["phase"] == "B" else local
            return h.RawHttpResponse(200, json.dumps({
                "status": "ok", "paths": {
                    "cwd": str(root), "effective_base_path": str(root),
                    "effective_masc_root": str(root / ".masc"),
                    "effective_has_masc_dir": True,
                },
            }).encode(), content_type="application/json")

        fixtures["/health"] = health
        fixtures["/health?full=1"] = health

    def interact(process, fd, _slave, output, _base):
        try:
            h.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=10)
            assert h.wait_for_fixture_event(
                process, fd, output, initial_gate_read, timeout=10
            ), "initial matching workspace did not request Gate"
            h.drain_until_quiet(process, fd, output)
            state["hold_gate"] = True
            h.palette_go(process, fd, output, b"go Approvals", b"MASC Approvals")
            assert h.wait_for_fixture_event(
                process, fd, output, held_gate.requested, timeout=10
            ), "Approvals did not start the held Gate read"
            with lock:
                state["phase"] = "B"
            before = len(output)
            held_gate.release.set()
            assert h.wait_for_fixture_event(
                process, fd, output, held_gate.completed, timeout=10
            ), "B Gate fixture did not complete"
            # This text is rendered from the Gate mailbox's rejected result,
            # after the client's post-read B identity probe. It cannot appear
            # merely because the HTTP fixture finished writing its response.
            rejection = b"workspace changed before the action completed"
            h.wait_for_output(process, fd, output, rejection, start=before, timeout=10)
            shown = h.resize_and_wait(
                process, fd, output, rows=40, columns=161,
                needle=b"MASC Approvals", controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            visible = h.screen_text(shown)
            assert rejection in visible and b"foreign-gate-before-identity" not in visible, visible
            with lock:
                assert ("/health", "B") in calls, calls
                assert (BRIEFING, "B") not in calls, (
                    "ordinary B refresh ran before the Gate rejection", calls)
            home.assert_no_decision_posts(requests)
            os.write(fd, b"q")
        finally:
            held_gate.release.set()

    h.run_terminal_scenario(
        executable, description="Gate rejects B before ordinary identity refresh",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare, refresh=60.0,
    )
    home.assert_no_decision_posts(requests)


def goal_drop_arm_withdrawal_journey(executable):
    """Withdraw an armed Goal on an async B reading, then recover A."""
    fixtures = cards.fixtures_with_held([])
    requests = []
    goal = dict(h.planning_goal("goal-arm-40176", "Goal arm workspace proof"),
                phase="awaiting_confirmation", criterion_revision="r1",
                created_at="2026-09-29T00:00:00Z", updated_at="2026-09-29T00:00:00Z")
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([goal])
    state = {"foreign": False, "after_foreign": False}
    foreign_read = threading.Event()
    recovered_read = threading.Event()

    def prepare(base):
        home.seed_goals(base, [{key: value for key, value in goal.items()
                               if key not in ("verification", "verifier_unreconciled") }])
        local = Path(base).resolve()
        foreign = local / "goal-arm-foreign-B"
        (foreign / ".masc").mkdir(parents=True)
        state.update(local=local, foreign_root=foreign)

        def health():
            root = foreign if state["foreign"] else local
            if state["foreign"]:
                foreign_read.set()
            elif state["after_foreign"]:
                recovered_read.set()
            return h.RawHttpResponse(200, json.dumps({
                "status": "ok", "paths": {
                    "cwd": str(root), "effective_base_path": str(root),
                    "effective_masc_root": str(root / ".masc"),
                    "effective_has_masc_dir": True,
                },
            }).encode(), content_type="application/json")

        fixtures["/health"] = health
        fixtures["/health?full=1"] = health

    def assert_no_drop():
        assert not any(path == "/api/v1/tools/masc_goal_transition"
                       for path, _body in requests), requests

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Confirm Goal", start=0, timeout=10)
        h.resize_and_wait(process, fd, output, rows=40, columns=160, needle=b"Confirm Goal")
        cards.select_home(process, fd, output, b"goal-arm-40176", destinations=3)
        h.send_and_wait(process, fd, output, b"\r", b"Goal arm workspace proof")
        h.send_and_wait(process, fd, output, b"x", b"press x again")
        assert_no_drop()
        # No key is sent between arming and identity withdrawal: the normal
        # periodic read must clear the arm, not the generic key dispatcher.
        state["foreign"] = True
        start = len(output)
        assert h.wait_for_fixture_event(process, fd, output, foreign_read, timeout=10), (
            "periodic refresh did not read replacement B")
        h.wait_for_output(process, fd, output, b"[workspace mismatch]",
                          start=start, timeout=10)
        withdrawn = h.resize_and_wait(
            process, fd, output, rows=40, columns=161,
            needle=b"MASC Dashboard", controls=(h.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        assert b"MASC Dashboard" in h.screen_text(withdrawn), withdrawn
        state["foreign"] = False
        state["after_foreign"] = True
        recovered_start = len(output)
        assert h.wait_for_fixture_event(process, fd, output, recovered_read, timeout=10), (
            "periodic refresh did not reread recovered A")
        h.wait_for_output(process, fd, output, b"Goal arm workspace proof",
                          start=recovered_start, timeout=10)
        recovered = h.resize_and_wait(
            process, fd, output, rows=40, columns=162,
            needle=b"MASC Dashboard", controls=(h.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        recovered_visible = h.screen_text(recovered)
        assert b"MASC Dashboard" in recovered_visible, recovered_visible
        assert b"Goal arm workspace proof" in recovered_visible, recovered_visible
        assert b"[workspace mismatch]" not in recovered_visible, recovered_visible
        # Reopen the recovered Goal through its current Home card. The first
        # Drop key must arm again instead of dispatching the withdrawn arm.
        cards.select_home(process, fd, output, b"goal-arm-40176", destinations=3)
        h.send_and_wait(process, fd, output, b"\r", b"Goal arm workspace proof")
        h.send_and_wait(process, fd, output, b"x", b"press x again")
        assert_no_drop()
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Goal Drop arm clears across B and A recovery",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare, refresh=1.0,
    )
    assert_no_drop()


def held_identity_boundary_journey(executable, *, boundary):
    """Probe each held read boundary and the separate decision admission."""
    fixtures = cards.fixtures_with_held([])
    requests = []
    phase = {"armed": False, "foreign": False, "held_reads": 0}
    probed_foreign = threading.Event()
    initial_read = threading.Event()
    call_id = "held-boundary-" + boundary
    row = cards.held(call_id, "held identity boundary " + boundary)

    def read_held():
        phase["held_reads"] += 1
        if not phase["armed"]:
            initial_read.set()
            rows = [row] if boundary == "decision" else []
        else:
            rows = [row]
            if boundary == "after-read":
                phase["foreign"] = True
        return 200, {"pending": copy.deepcopy(rows)}

    fixtures[cards.HELD_PATH] = read_held

    def prepare(base):
        home.seed_goals(base)
        local = Path(base).resolve()
        foreign = local / "held-foreign-B"
        (foreign / ".masc").mkdir(parents=True)

        def health():
            root = foreign if phase["foreign"] else local
            if phase["foreign"]:
                probed_foreign.set()
            return h.RawHttpResponse(200, json.dumps({
                "status": "ok", "paths": {
                    "cwd": str(root), "effective_base_path": str(root),
                    "effective_masc_root": str(root / ".masc"),
                    "effective_has_masc_dir": True,
                },
            }).encode(), content_type="application/json")

        fixtures["/health"] = health
        fixtures["/health?full=1"] = health

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=10)
        assert h.wait_for_fixture_event(process, fd, output, initial_read, timeout=10)
        h.drain_until_quiet(process, fd, output)
        if boundary == "decision":
            h.palette_go(process, fd, output, b"go approvals", call_id.encode())
            h.send_and_wait(process, fd, output, b"\r", call_id.encode())
            h.drain_until_quiet(process, fd, output)
        before = phase["held_reads"]
        phase["armed"] = True
        phase["foreign"] = boundary != "after-read"
        start = len(output)
        if boundary == "decision":
            os.write(fd, b"y")
        else:
            h.palette_go(process, fd, output, b"go approvals", b"MASC Approvals")
        assert h.wait_for_fixture_event(process, fd, output, probed_foreign, timeout=10)
        h.wait_for_output(process, fd, output,
                          b"workspace changed before the action completed",
                          start=start, timeout=10)
        h.drain_until_quiet(process, fd, output)
        if boundary == "before-read":
            assert phase["held_reads"] == before, phase
        elif boundary == "after-read":
            assert phase["held_reads"] > before, phase
            assert call_id.encode() not in h.screen_text(bytes(output)), output
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="held-call identity " + boundary,
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare, refresh=60.0,
    )
    home.assert_no_decision_posts(requests)


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    for unread in (False, True):
        scoped_identity_journey(executable, unread=unread)
    superseded_scoped_match_journey(executable)
    gate_before_identity_refresh_journey(executable)
    goal_drop_arm_withdrawal_journey(executable)
    for boundary in ("before-read", "after-read", "decision"):
        held_identity_boundary_journey(executable, boundary=boundary)
    print("Home scoped identity PTY: PASS (8 scenarios)")
