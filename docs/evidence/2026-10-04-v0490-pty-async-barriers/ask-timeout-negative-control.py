"""A delayed fixture admission must not relabel a natural timeout as cancellation.

Usage: DYLD_LIBRARY_PATH=<artifact>/lib python3 <this-file> <native-tui>
This diagnostic deliberately keeps workspace A and waits for the real client's
10s timeout. It is not a product workspace-withdrawal success scenario.
"""
from pathlib import Path
import json, os, sys, time
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "test"))
import test_tui_keyboard_input as h
import test_tui_remote_workspace_history_pty as authority

binary = str(Path(sys.argv[1]).resolve())
fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
wire = authority.WorkspaceWire(fixtures[authority.ROSTER_PATH][1])
gate = h.GatedHttpResponse((200, {"ok": True}), hold_seconds=30)
connections = []
admitted = []
observed = {}
def answer(method, connection):
    assert method == "POST", method
    time.sleep(3.0)  # Intentional delayed admission, greater than the 2s margin.
    connections.append(connection)
    admitted.append(time.monotonic())
    return gate()
fixtures.update({authority.ROSTER_PATH: wire.roster, "/health": wire.health,
    "/health?full=1": wire.health, h.KEEPER_ASKS_PATH: h.keeper_asks_response,
    h.KEEPER_ASK_ANSWER_PATH: h.ConnectionHttpResponse(answer)})
def interact(process, fd, slave, output, base):
    try:
        h.resize_and_wait(process, fd, output, rows=40, columns=authority.TERMINAL_COLUMNS,
            needle=b"MASC Dashboard", controls=(h.FULL_REDRAW,))
        h.palette_go(process, fd, output, b"go Approvals", b"Questions waiting on you")
        h.send_and_wait(process, fd, output, b"a", b"Enter:answer")
        h.send_and_wait(process, fd, output, b"1", b"1 (o) ")
        h.send_and_wait(process, fd, output, b"\r", b"Press Enter again to send")
        dispatched = time.monotonic()
        deadline = dispatched + authority.WAIT_SECONDS
        os.write(fd, b"\r")
        assert h.wait_for_fixture_event(process, fd, output, gate.requested,
            timeout=authority.WAIT_SECONDS), "delayed Ask was not admitted"
        assert len(connections) == 1
        assert admitted[0] - dispatched > 2.0
        assert not authority.connection_disconnected(connections[0])
        remaining = deadline - time.monotonic()
        assert remaining > 0
        premature = h.wait_for_fixture_state(process, fd, output,
            lambda: authority.connection_disconnected(connections[0]), timeout=remaining)
        assert not premature, "uncanceled connection passed the pre-dispatch deadline"
        assert process.poll() is None
        assert not gate.release.is_set() and not gate.completed.is_set()
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: authority.connection_disconnected(connections[0]), timeout=authority.WAIT_SECONDS), \
            "the uncanceled client's ordinary HTTP timeout was not observed"
        disconnected = time.monotonic()
        assert disconnected >= deadline
        assert disconnected < admitted[0] + authority.WAIT_SECONDS, \
            "negative control did not exercise the old admission-anchored false-green window"
        assert wire.phase == "a", "negative control accidentally changed workspace"
        observed.update(status="PASS_EXPECTED_REJECTION", admission_delay_s=admitted[0]-dispatched,
            disconnect_after_dispatch_s=disconnected-dispatched,
            dispatch_deadline_s=authority.WAIT_SECONDS,
            old_admission_deadline_would_accept=True)
        gate.release.set()
        h.write_all(fd, output, b"\x1b")
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: b"Enter:answer" not in authority.screen(output)
                and b"Press Enter again to send" not in authority.screen(output),
            timeout=authority.WAIT_SECONDS), "timed-out Ask editor did not close"
        h.palette_go(process, fd, output, b"go Keepers", b"MASC Keepers")
        os.write(fd, b"q")
    finally:
        gate.release.set()
h.run_terminal_scenario(binary, description="negative control: delayed admission cannot hide ordinary Ask timeout",
    interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
    refresh=0.5, terminal_cols=authority.TERMINAL_COLUMNS)
print("ASK_TIMEOUT_NEGATIVE_CONTROL " + json.dumps(observed, sort_keys=True))
