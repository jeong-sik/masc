"""Workspace A's held facts cannot land in workspace B's browser (#41163).

The facts request key names a Keeper, not a workspace: without the
authority boundary, a same-port identity change from A to B leaves the
owner pending, and A's late response completes into B's browser. The
regression holds A's facts response, walks the identity to B, releases
A's answer, and proves only a fresh B read owns the display.
"""

import json
import os
import sys
import threading

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_memory as _keyboard_memory

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_tui_remote_workspace_history_pty import (  # noqa: E402
    ROSTER_PATH,
    WorkspaceWire,
)

A_CLAIM = b"workspace-a-held-fact"
B_CLAIM = b"workspace-b-fresh-fact"


def facts_payload(claim: str, keeper: str = "alpha"):
    fixtures = _keyboard_memory.memory_facts_http_fixtures()
    fixture = fixtures["/api/v1/keepers/alpha/memory-facts"]
    assert isinstance(fixture, tuple) and isinstance(fixture[1], dict)
    body = fixture[1]
    body["keeper"] = keeper
    # The snapshot nests each store's facts under its own key; the claim is
    # the field the pane renders, so rewriting it makes the authority leak --
    # A's rows landing in B's browser -- visible as a byte on the screen.
    ordinary = body["ordinary"]
    assert isinstance(ordinary, dict) and ordinary.get("present") is True
    facts = ordinary["facts"]
    assert isinstance(facts, list) and isinstance(facts[0], dict)
    facts[0]["claim"] = claim
    return 200, body


def run(executable: str, *, detail: bool = False) -> None:
    fixtures = _keyboard_memory.memory_facts_http_fixtures()
    roster = fixtures[ROSTER_PATH]
    assert isinstance(roster, tuple) and isinstance(roster[1], dict)
    wire = WorkspaceWire(roster[1])
    release_a = threading.Event()
    a_read_started = threading.Event()
    facts_reads: list[tuple[str, bool, str]] = []
    b_keeper = "beta" if detail else "alpha"
    a_reads = 0
    requests: _keyboard_harness.HttpRequests = []

    def facts(keeper: str):
        nonlocal a_reads
        with wire.lock:
            phase = wire.phase
            if phase == "a":
                a_reads += 1
        facts_reads.append((phase, release_a.is_set(), keeper))
        if phase == "a":
            if detail and a_reads == 1:
                return facts_payload("workspace-a-prior-fact")
            a_read_started.set()
            assert release_a.wait(timeout=30), "held A facts read was never released"
            return facts_payload("workspace-a-held-fact")
        return facts_payload("workspace-b-fresh-fact", keeper)

    def memory_health():
        with wire.lock:
            phase = wire.phase
        payload = _keyboard_memory.memory_facts_http_fixtures()[
            "/api/v1/dashboard/keeper-memory-health"]
        assert isinstance(payload, tuple) and isinstance(payload[1], dict)
        body = payload[1]
        keepers = body["keepers"]
        assert isinstance(keepers, list) and keepers and isinstance(keepers[0], dict)
        keepers[0]["source_revision"] = 47 if phase == "b" else 2
        keepers[0]["keeper_id"] = b_keeper if phase == "b" else "alpha"
        return 200, body

    fixtures["/api/v1/dashboard/keeper-memory-health"] = memory_health
    fixtures["/api/v1/keepers/alpha/memory-facts"] = lambda: facts("alpha")
    fixtures["/api/v1/keepers/beta/memory-facts"] = lambda: facts("beta")
    fixtures[ROSTER_PATH] = wire.roster
    fixtures["/health"] = wire.health
    fixtures["/health?full=1"] = wire.health

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.palette_go(process, fd, output, b"go Memory", b"MASC Memory")
        _keyboard_harness.wait_for_output(
            process, fd, output, b"alpha", start=0, timeout=10)
        # Enter on the keeper row starts its facts read; the held response is
        # what the authority boundary must place on the right workspace.
        os.write(fd, b"\r")
        if detail:
            _keyboard_harness.wait_for_output(process, fd, output,
                b"workspace-a-prior-fact", start=0, timeout=10)
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"FACT DETAIL")
            os.write(fd, b"r")
        assert _keyboard_harness.wait_for_fixture_event(
            process, fd, output, a_read_started, timeout=10
        ), "workspace A's facts read never started"
        # Publishing B and observing its GET callbacks precede the reducer.
        # The mismatch badge is drawn from the applied workspace authority;
        # it must be visible before A is allowed to complete.
        wire.publish("b")
        try:
            assert _keyboard_harness.wait_for_fixture_state(
                process, fd, output,
                lambda: b"[workspace mismatch]" in _keyboard_harness.screen_text(bytes(output)),
                timeout=10,
            ), f"workspace B identity not applied: {_keyboard_harness.screen_text(bytes(output))!r}"
            assert _keyboard_harness.wait_for_fixture_state(
                process, fd, output,
                lambda: b"r47 i1" in _keyboard_harness.screen_text(bytes(output))
                and b_keeper.encode() in _keyboard_harness.screen_text(bytes(output)),
                timeout=10,
            ), f"workspace B health did not replace A's facts navigation: {_keyboard_harness.screen_text(bytes(output))!r}"
        finally:
            # Release the owned server gate even when the applied-state check
            # fails, so fixture teardown cannot strand A's response handler.
            release_a.set()
        # A's answer arrives after the applied switch, never just after a GET.
        _keyboard_harness.drain_until_quiet(process, fd, output, cap=2)
        folded = _keyboard_harness.screen_text(bytes(output))
        if A_CLAIM in folded or b"workspace-a-prior-fact" in folded:
            raise AssertionError(
                f"workspace A's held facts populated workspace B's browser: {folded!r}"
            )
        # The applied B health row, not a retained A browser selection, owns
        # Enter. No refresh key is used to hide an inherited unread browser.
        start = len(output)
        os.write(fd, b"\r")

        def b_read_after_release():
            return [
                call for call, after_release, keeper in facts_reads
                if call == "b" and after_release and keeper == b_keeper
            ] != []

        assert _keyboard_harness.wait_for_fixture_state(
            process, fd, output, b_read_after_release, timeout=10
        ), f"workspace B never ran its own facts read after A's release; reads={facts_reads!r}"
        # Rejection of A is half the contract; acceptance of B is the other.
        # The fresh completion must reach the browser, not merely start;
        # wait_for_output raises on timeout, so a bare call is the check.
        _keyboard_harness.wait_for_output(
            process, fd, output, B_CLAIM, start=start, timeout=10)
        _keyboard_harness.drain_until_quiet(process, fd, output, cap=1)
        folded = _keyboard_harness.screen_text(bytes(output))
        if A_CLAIM in folded or b"workspace-a-prior-fact" in folded:
            raise AssertionError(
                f"workspace A's claim survived into workspace B's view: {folded!r}"
            )
        writes = [(path, body) for path, body in requests
                  if path != "/mcp" or json.loads(body).get("method") != "initialize"]
        if writes:
            raise AssertionError(f"facts navigation sent a domain write: {writes!r}")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="held workspace-A facts cannot populate workspace-B's " + ("detail" if detail else "browser"),
        interact=interact,
        prepare_workspace=wire.prepare,
        http_fixtures=fixtures,
        http_requests=requests,
        refresh=0.5,
        terminal_cols=160,
    )


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    run(executable)
    run(executable, detail=True)
    print("Memory facts authority PTY: PASS (2 scenarios)")
