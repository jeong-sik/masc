"""Workspace A's held facts cannot land in workspace B's browser (#41163).

The facts request key names a Keeper, not a workspace: without the
authority boundary, a same-port identity change from A to B leaves the
owner pending, and A's late response completes into B's browser. The
regression holds A's facts response, walks the identity to B, releases
A's answer, and proves only a fresh B read owns the display.
"""

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


def facts_payload(claim: str):
    fixtures = _keyboard_memory.memory_facts_http_fixtures()
    fixture = fixtures["/api/v1/keepers/alpha/memory-facts"]
    assert isinstance(fixture, tuple) and isinstance(fixture[1], dict)
    body = fixture[1]
    # The snapshot nests each store's facts under its own key; the claim is
    # the field the pane renders, so rewriting it makes the authority leak --
    # A's rows landing in B's browser -- visible as a byte on the screen.
    ordinary = body["ordinary"]
    assert isinstance(ordinary, dict) and ordinary.get("present") is True
    facts = ordinary["facts"]
    assert isinstance(facts, list) and isinstance(facts[0], dict)
    facts[0]["claim"] = claim
    return 200, body


def run(executable: str) -> None:
    fixtures = _keyboard_memory.memory_facts_http_fixtures()
    roster = fixtures[ROSTER_PATH]
    assert isinstance(roster, tuple) and isinstance(roster[1], dict)
    wire = WorkspaceWire(roster[1])
    release_a = threading.Event()
    a_read_started = threading.Event()
    facts_reads: list[tuple[str, bool]] = []

    def facts():
        with wire.lock:
            phase = wire.phase
        facts_reads.append((phase, release_a.is_set()))
        if phase == "a":
            a_read_started.set()
            assert release_a.wait(timeout=30), "held A facts read was never released"
            return facts_payload("workspace-a-held-fact")
        return facts_payload("workspace-b-fresh-fact")

    fixtures["/api/v1/keepers/alpha/memory-facts"] = facts
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
        assert _keyboard_harness.wait_for_fixture_event(
            process, fd, output, a_read_started, timeout=10
        ), "workspace A's facts read never started"
        # The identity walks to workspace B while A's facts answer is held.
        # The footer spelling differs per surface, so the proof is the wire:
        # a B-phase reading means the TUI asked with workspace B's identity.
        wire.publish("b")

        def b_observed():
            # Two B-phase health observations: the first is the fixture
            # being called mid-pass, before the reading has applied; the
            # second proves the pass completed, the identity applied, and
            # the workspace authority advanced -- the boundary the late A
            # response must be dropped at, and the one the fresh B read has
            # to be launched under to survive its own delivery.
            with wire.lock:
                return (
                    sum(
                        1
                        for event in wire.events
                        if event.get("event") == "health"
                        and str(event.get("phase", "")).startswith("b")
                    )
                    >= 2
                )

        assert _keyboard_harness.wait_for_fixture_state(
            process, fd, output, b_observed, timeout=10
        ), "workspace B's identity was never read"
        # A's answer arrives after the switch: it must not populate B's view.
        release_a.set()
        _keyboard_harness.drain_until_quiet(process, fd, output, cap=2)
        folded = _keyboard_harness.screen_text(bytes(output))
        if A_CLAIM in folded:
            raise AssertionError(
                f"workspace A's held facts populated workspace B's browser: {folded!r}"
            )
        # A fresh B read owns the result: the proof is the wire, because the
        # pane a claim renders in is a view question, not an authority one.
        # The withdraw may have left another surface in front, so re-enter
        # Memory through the palette and select alpha again.
        reentry = len(output)
        _keyboard_harness.palette_go(process, fd, output, b"go Memory", b"MASC Memory")
        _keyboard_harness.wait_for_output(
            process, fd, output, b"MASC Memory", start=reentry, timeout=10)
        # Enter is a no-op while a keeper browser is already open; r is the
        # reload gesture that must own a fresh workspace-B read.
        start = len(output)
        os.write(fd, b"r")

        def b_read_after_release():
            return [
                call for call, after_release in facts_reads
                if call == "b" and after_release
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
        if A_CLAIM in folded:
            raise AssertionError(
                f"workspace A's claim survived into workspace B's view: {folded!r}"
            )
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="held workspace-A facts cannot populate workspace-B's browser",
        interact=interact,
        prepare_workspace=wire.prepare,
        http_fixtures=fixtures,
        refresh=0.5,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Memory facts authority PTY: PASS (1 scenario)")
