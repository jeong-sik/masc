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

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_render.ml",
)
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
    fixtures[h.KEEPER_ASKS_PATH] = track(
        h.KEEPER_ASKS_PATH,
        lambda: copy.deepcopy(ask if state["changed"] and not unread else empty_asks),
    )
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
            root = foreign if state["changed"] else local
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
                paths = json.loads(response.body)["paths"]
                assert paths["effective_base_path"] == state["foreign"]
                assert paths["effective_masc_root"] == state["foreign"] + "/.masc"
                assert paths["effective_base_path"] != state["local"]
        # Health must precede the newly fetched decision source, not merely
        # happen eventually after foreign rows have already become actionable.
        decision_path = cards.OPERATOR_PATH if unread else h.KEEPER_ASKS_PATH
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
        h.press_label_on_screen(process, fd, output, b"Dashboard", row=1, needle=label)
        identity = (b"workspace identity not read; read history" if unread
                    else b"[workspace mismatch]")
        h.wait_for_output(process, fd, output, identity, start=start, timeout=10)
        assert_scoped(baseline)
        h.resize_and_wait(process, fd, output, rows=40, columns=120,
                          needle=label, final_cursor=b"\x1b[?25l")
        cards.select_home(process, fd, output, label, destinations=4)
        detail = label if unread else b"ship the cold-start change now?"
        h.send_and_wait(process, fd, output, b"\r", detail)
        home.assert_no_decision_posts(requests)
        if unread:
            h.send_and_wait(process, fd, output, b"y", b"Press y again:")
            home.assert_no_decision_posts(requests)
            h.send_and_wait(process, fd, output, b"y",
                            b"Cannot decide: workspace identity is unverified")
        else:
            h.send_and_wait(process, fd, output, b"1",
                            re.compile(rb"\(o\) (?:\x1b\[[0-9;:]*m)*c-yes"))
            refused = h.send_and_wait(
                process, fd, output, b"\r",
                b"Cannot answer: workspace identity is unverified; draft retained",
            )
            assert b"(o) c-yes" in h.screen_text(refused), "refusal lost the answer draft"
        assert_scoped(baseline)
        h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
        cards.assert_selected(output, label)
        os.write(fd, b"q")
        state["baseline"] = baseline

    h.run_terminal_scenario(
        executable,
        description="Home scoped identity " + ("503 refuses operator confirmation" if unread
                                               else "A to B refuses foreign question answer"),
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
    briefing = fixtures[BRIEFING]

    def record(path):
        with lock:
            phase = state["phase"]
            calls.append((path, phase))
            return phase

    def read_briefing():
        record(BRIEFING)
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
        if phase in ("old-scoped", "released"):
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
            h.drain_until_quiet(process, fd, output)
            with lock:
                assert ("/health", "initial") in calls, calls
                baseline = calls.count((BRIEFING, "initial"))
                assert baseline >= 1, calls
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
            h.wait_for_output(process, fd, output, new_label, start=start, timeout=10)
            h.wait_for_output(process, fd, output, new_operator_label, start=start, timeout=10)
            replacement = h.resize_and_wait(
                process, fd, output, rows=40, columns=120,
                needle=new_operator_label, controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            visible = h.screen_text(replacement)
            for required in (b"[workspace mismatch]", new_label, new_operator_label):
                assert required in visible, ("new full current dataset was not applied", visible)
            assert old_label not in visible and old_operator_label not in visible, visible
            assert not gate.completed.is_set(), "mismatch was not applied before old completion"
            assert gate.calls == 1, "more than the first scoped decision GET was gated"
            with lock:
                assert calls.count((BRIEFING, "new-full")) == 1, calls
                assert ("/health", "new-full") in calls, calls
                assert calls.count((cards.OPERATOR_PATH, "new-full")) == 1, calls
                assert calls.index(("/health", "old-scoped")) < calls.index(
                    ("/health", "new-full")
                ) < calls.index((h.KEEPER_ASKS_PATH, "new-full")), calls
                state["phase"] = "released"
            gate.release.set()
            assert h.wait_for_fixture_event(process, fd, output, gate.completed, timeout=10), (
                "old scoped GET never completed after release"
            )
            # Consume the returned response and mailbox, then force a fresh
            # frame: accumulated pre-release mismatch bytes are not evidence.
            h.drain_until_quiet(process, fd, output, cap=1)
            drawn = h.resize_and_wait(
                process, fd, output, rows=40, columns=121,
                needle=b"Enter:open", controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            visible = h.screen_text(drawn)
            assert b"[workspace mismatch]" in visible, "old scoped A restored authority"
            assert new_label in visible and old_label not in visible, (
                "superseded scoped dataset replaced the newer full dataset", visible
            )
            assert new_operator_label in visible and old_operator_label not in visible, visible
            with lock:
                # No extra full tick or fresh health read may repair a faulty
                # restoration and make this assertion pass accidentally.
                assert sum(path == BRIEFING for path, _ in calls) == baseline + 1, calls
                assert ("/health", "released") not in calls, calls
            cards.select_home(process, fd, output, new_label, destinations=5)
            h.send_and_wait(process, fd, output, b"\r", b"ship the cold-start change now?")
            h.send_and_wait(process, fd, output, b"1",
                            re.compile(rb"\(o\) (?:\x1b\[[0-9;:]*m)*c-yes"))
            h.send_and_wait(process, fd, output, b"\r",
                            b"Cannot answer: workspace identity is unverified; draft retained")
            home.assert_no_decision_posts(requests)
            h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
            os.write(fd, b"q")
        finally:
            gate.release.set()

    h.run_terminal_scenario(
        executable, description="Home drops old scoped A after newer full B mismatch",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=prepare, refresh=60.0, starts_in_chat=True,
    )
    home.assert_no_decision_posts(requests)


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    for unread in (False, True):
        scoped_identity_journey(executable, unread=unread)
    superseded_scoped_match_journey(executable)
    print("Home scoped identity PTY: PASS (3 scenarios)")
