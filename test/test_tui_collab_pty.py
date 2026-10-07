"""Observe decoded machine frames, paste invite fields, and enter control during a pending read."""
import base64
import json
import os
from pathlib import Path
import sys
import threading
import urllib.parse

import tui_keyboard_harness as h


def live_answer(source, number):
    answer = {"source_kind": source, "state": "changed", "change_count": number,
              "incarnation": source,
              "screen": {"format": "rgb8", "width": 2, "height": 1,
                         "rgb_base64": base64.b64encode(b"\xff\x00\x00\x00\x00\xff").decode()}}
    if source == "msx_capture":
        answer["frame_number"] = number
    else:
        answer["activity"] = []
    return 200, answer


def run(executable):
    requests = []
    invites = []
    reads = []
    link = "https://play.example.test/play#collab-fixture-token"

    def inventory(body):
        if body:
            assert json.loads(body) == {"name": "guest1", "hours": 12}
            invites[:] = [{"name": "guest1", "expires_at": "2026-10-08T00:00:00Z",
                          "expired": False, "holds_controller": False}]
            return 201, {**invites[0], "link": link}
        return 200, {"invites": invites.copy()}

    def revoke(method):
        assert method == "DELETE"
        invites.clear()
        return 200, {"name": "guest1", "revoked": True, "released_controller": False}

    def live(path):
        source = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)["source_kind"][0]
        reads.append(source)
        return live_answer(source, reads.count(source))

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            start = len(output)
            os.write(master, value)
            h.wait_for_output(process, master, output, needle, start=start, timeout=8)
            return start

        key(b":go Collab\r", b"No invites")
        first = key(b"m", b"frame 1 ")
        h.wait_for_output(process, master, output, b"38;2;255;0;0", start=first, timeout=8)
        h.wait_for_output(process, master, output, b"38;2;0;0;255", start=first, timeout=8)
        h.wait_for_output(process, master, output, b"frame 2 ", start=first, timeout=8)
        key(b"1\r\x1b[17~", b"Watching only")  # game key, Return and F6 must remain observations
        key(b"\x1b", b"MASC Collab")
        first = key(b"d", b"change 1 ")
        h.wait_for_output(process, master, output, b"38;2;255;0;0", start=first, timeout=8)
        h.wait_for_output(process, master, output, b"change 2 ", start=first, timeout=8)
        key(b"1\r", b"Esc: back")
        key(b"\x1b", b"MASC Collab")
        key(b"n", b"Player name:")
        key(b"\x1b[200~guest1\x1b[201~", b"Player name: guest1")
        key(b"\r", b"Expires in hours:")
        key(b"\x15\x1b[200~12\x1b[201~", b"Expires in hours: 12")
        key(b"\r", link.encode())
        # Closing the card can precede the asynchronous inventory response.
        key(b"\x1b", "› guest1".encode())
        key(b"\r", link.encode())
        key(b"\x1b", b"MASC Collab")
        key(b"x", b"Revoke guest1?")
        key(b"\r", b"No invites")
        assert {"msx_capture", "dos_capture"}.issubset(reads)
        for path, body in requests:
            assert not path.startswith(("/api/v1/msx/", "/api/v1/dos/")), path
            assert b"collab-fixture-token" not in body
            if path == "/mcp":
                assert json.loads(body).get("method") in ("initialize", "notifications/initialized")
        key(b"\x1b", b"MASC Dashboard")
        os.write(master, b"q")

    h.run_terminal_scenario(executable,
        description="Collab observes machines and manages play links without Keeper chat",
        interact=interact,
        http_fixtures={"/api/v1/play/invites": h.RequestHttpResponse(inventory),
                       "/api/v1/play/invites/guest1": h.MethodHttpResponse(revoke),
                       "/api/v1/lane-addons/live": h.PathHttpResponse(live)},
        http_requests=requests)
    run_early_control(executable)
    run_pending_revoke(executable)
    run_issue_after_reopen(executable)
    run_workspace_withdrawal(executable)
    print("tui collab: PASS")


def run_early_control(executable):
    """F5 before the first live answer must recover a current frame and start the clock."""
    requests = []
    pending = h.GatedHttpResponse(live_answer("msx_capture", 1001),
                                 subsequent_response=live_answer("msx_capture", 1002),
                                 hold_seconds=15)

    def live(path):
        source = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)["source_kind"][0]
        assert source == "msx_capture", source
        return pending()

    tick = {"loaded": True, "number": 1003, "change_count": 1003,
            "incarnation": "msx_capture", "width": 2, "height": 1,
            "mode": "SCREEN2", "cartridge": "fixture.rom", "disk": None,
            "players": [], "rgb_base64": base64.b64encode(b"\xff\x00\x00\x00\x00\xff").decode()}

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            start = len(output)
            os.write(master, value)
            h.wait_for_output(process, master, output, needle, start=start, timeout=8)

        try:
            key(b":go Collab\r", b"No invites")
            # The fixture intentionally leaves overview health unavailable.
            # Wait for the actual held request, independent of its status label.
            os.write(master, b"m")
            assert h.wait_for_fixture_event(process, master, output, pending.requested, timeout=8)
            key(b"\x1b[15~", b"Controlling")
            assert not pending.completed.is_set(), "F5 did not run while the first read was held"
            start = len(output)
            pending.release.set()
            h.wait_for_output(process, master, output, b"frame 1002 ", start=start, timeout=8)
            h.wait_for_http_request(process, master, output, requests, path="/api/v1/msx/tick")
            h.wait_for_output(process, master, output, b"frame 1003", start=start, timeout=8)
            assert b"frame 1001 " not in output[start:], "the abandoned observation replaced the current view"
            key(b"\x1b", b"MASC Collab")
            key(b"\x1b", b"MASC Dashboard")
            os.write(master, b"q")
        finally:
            pending.release.set()

    h.run_terminal_scenario(executable,
        description="Collab control recovers when F5 precedes its first live frame",
        interact=interact,
        http_fixtures={"/api/v1/play/invites": (200, {"invites": []}),
                       "/api/v1/lane-addons/live": h.PathHttpResponse(live),
                       "/api/v1/msx/tick": (200, tick)},
        http_requests=requests)


def invite_row(name):
    return {"name": name, "expires_at": "2030-01-01T00:00:00Z",
            "expired": False, "holds_controller": False}


def run_pending_revoke(executable):
    """A link notice cannot unlock a pending revoke; its receipt refreshes a reopened hub."""
    rows = [invite_row("alpha"), invite_row("beta")]
    gate = h.GatedHttpResponse((200, {"name": "alpha", "revoked": True,
                                     "released_controller": False}), hold_seconds=30)
    mutations = []

    def inventory(body):
        assert not body, "issue must wait for the pending revoke receipt"
        return 200, {"invites": rows.copy()}

    def revoke(method):
        assert method == "DELETE"
        mutations.append("alpha")
        rows[:] = [invite_row("beta")]
        return gate()

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            start = len(output)
            os.write(master, value)
            h.wait_for_output(process, master, output, needle, start=start, timeout=8)

        try:
            key(b":go Collab\r", "› alpha".encode())
            key(b"x", b"Revoke alpha?")
            key(b"\r", b"Waiting for the server")
            assert h.wait_for_fixture_event(process, master, output, gate.requested, timeout=8)
            key(b"\r", b"one-time link is not retained")
            # If that unrelated notice released pending state, n opens a form
            # and q is text instead of closing the hub.
            key(b"nxq", b"MASC Dashboard")
            key(b":go Collab\r", "› beta".encode())
            key(b"nalpha\r", b"Expires in hours:")
            key(b"\r", b"An invite change is still pending")
            key(b"q", b"MASC Dashboard")
            key(b":go Collab\r", "› beta".encode())
            refreshed_expiry = "2031-02-03T04:05:06Z"
            rows[0]["expires_at"] = refreshed_expiry
            before_receipt = len(output)
            gate.release.set()
            h.wait_for_output(process, master, output, refreshed_expiry.encode(),
                              start=before_receipt, timeout=8)
            key(b"x", b"Revoke beta?")
            key(b"\x1b", "› beta".encode())
            key(b"q", b"MASC Dashboard")
            key(b":go Collab\r", "› beta".encode())
            key(b"q", b"MASC Dashboard")
            assert mutations == ["alpha"], mutations
            os.write(master, b"q")
        finally:
            gate.release.set()

    h.run_terminal_scenario(executable,
        description="Collab notices preserve pending revocation and reopen refreshes current selection",
        interact=interact,
        http_fixtures={"/api/v1/play/invites": h.RequestHttpResponse(inventory),
                       "/api/v1/play/invites/alpha": h.MethodHttpResponse(revoke)})


def run_issue_after_reopen(executable):
    """An issued card survives same-workspace close/reopen and updates the current inventory."""
    rows = []
    link = "https://play.example.test/play#reopened-invite-token"
    gate = h.GatedHttpResponse((201, {**invite_row("guest"), "link": link}), hold_seconds=30)
    issued = []
    revokes = []

    def revoke(method):
        revokes.append(method)
        return 200, {"name": "guest", "revoked": True, "released_controller": False}

    def inventory(body):
        if not body:
            return 200, {"invites": rows.copy()}
        request = json.loads(body)
        assert request == {"name": "guest", "hours": 24}, request
        issued.append(request)
        rows[:] = [invite_row("guest")]
        return gate()

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            start = len(output)
            os.write(master, value)
            h.wait_for_output(process, master, output, needle, start=start, timeout=8)

        try:
            key(b":go Collab\r", b"No invites")
            key(b"nguest\r", b"Expires in hours:")
            key(b"\r", b"Waiting for the server")
            assert h.wait_for_fixture_event(process, master, output, gate.requested, timeout=8)
            key(b"q", b"MASC Dashboard")
            key(b":go Collab\r", "› guest".encode())
            key(b"x", b"Revoke guest?")
            key(b"\r", b"An invite change is still pending")
            key(b"nnext\r", b"Expires in hours:")
            key(b"\r", b"An invite change is still pending")
            key(b"q", b"MASC Dashboard")
            key(b":go Collab\r", "› guest".encode())
            start = len(output)
            gate.release.set()
            h.wait_for_output(process, master, output, link.encode(), start=start, timeout=8)
            key(b"\x1b", "› guest".encode())
            key(b"q", b"MASC Dashboard")
            key(b":go Collab\r", "› guest".encode())
            key(b"\r", link.encode())
            key(b"\x1b", b"MASC Collab")
            key(b"q", b"MASC Dashboard")
            assert len(issued) == 1, issued
            assert revokes == [], "revoke overtook its pending issue receipt"
            os.write(master, b"q")
        finally:
            gate.release.set()

    h.run_terminal_scenario(executable,
        description="Collab issue receipt refreshes the currently reopened owner and retains its card",
        interact=interact,
        http_fixtures={"/api/v1/play/invites": h.RequestHttpResponse(inventory),
                       "/api/v1/play/invites/guest": h.MethodHttpResponse(revoke)})


def run_workspace_withdrawal(executable):
    """A -> B withdraws rows, confirmation, cards and pending state; late A receipts stay retired."""
    current = {"phase": "a", "base": None}
    rows = {"a": [], "b": [invite_row("shared")]}
    health_b = threading.Event()
    health_unknown = threading.Event()
    late_link = "https://a.example.test/play#late-workspace-a-token"
    old_link = "https://a.example.test/play#shared-workspace-a-token"
    new_link = "https://b.example.test/play#fresh-workspace-b-token"
    late = h.GatedHttpResponse((201, {**invite_row("late"), "link": late_link}), hold_seconds=30)
    requests = []
    issued = []

    def prepare(base):
        current["base"] = str(Path(base).resolve())

    def health():
        if current["phase"] == "unknown":
            health_unknown.set()
            return h.RawHttpResponse(503, b'{"error":"fixture identity unavailable"}',
                                     content_type="application/json")
        base = current["base"]
        if current["phase"] == "b":
            base = str(Path(base, "workspace-b"))
            health_b.set()
        _, payload = h.fleet_safety_fixture()
        payload["paths"] = {"effective_base_path": base, "effective_masc_root": str(Path(base, ".masc"))}
        return h.RawHttpResponse(200, json.dumps(payload).encode(), content_type="application/json")

    def inventory(body):
        phase = current["phase"]
        if not body:
            return 200, {"invites": rows[phase].copy()}
        name = json.loads(body)["name"]
        issued.append((phase, name))
        if (phase, name) == ("a", "late"):
            answer = late()
        elif (phase, name) == ("a", "shared"):
            answer = 201, {**invite_row(name), "link": old_link}
        elif (phase, name) == ("b", "fresh"):
            answer = 201, {**invite_row(name), "link": new_link}
        else:
            raise AssertionError((phase, name))
        rows[phase].append(invite_row(name))
        return answer

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            start = len(output)
            os.write(master, value)
            h.wait_for_output(process, master, output, needle, start=start, timeout=8)

        try:
            key(b":go Collab\r", b"No invites")
            key(b"nshared\r", b"Expires in hours:")
            key(b"\r", old_link.encode())
            key(b"\x1b", "› shared".encode())
            unknown_start = len(output)
            current["phase"] = "unknown"
            assert h.wait_for_fixture_event(process, master, output, health_unknown, timeout=8)
            h.wait_for_output(process, master, output, b"MASC Dashboard", start=unknown_start, timeout=8)
            recovering = len(output)
            current["phase"] = "a"
            h.wait_for_output(process, master, output,
                ("Base: " + current["base"]).encode(), start=recovering, timeout=8)
            key(b":go Collab\r", "› shared".encode())
            key(b"\r", old_link.encode())
            key(b"\x1b", "› shared".encode())
            key(b"nlate\r", b"Expires in hours:")
            key(b"\r", b"Waiting for the server")
            assert h.wait_for_fixture_event(process, master, output, late.requested, timeout=8)
            key(b"q", b"MASC Dashboard")
            key(b":go Collab\r", "› shared".encode())
            key(b"x", b"Revoke shared?")
            boundary = len(output)
            current["phase"] = "b"
            assert h.wait_for_fixture_event(process, master, output, health_b, timeout=8)
            h.wait_for_output(process, master, output, b"MASC Dashboard", start=boundary, timeout=8)
            late.release.set()
            assert h.wait_for_fixture_event(process, master, output, late.completed, timeout=8)
            key(b":go Collab\r", "› shared".encode())
            key(b"\r", b"one-time link is not retained")
            key(b"nfresh\r", b"Expires in hours:")
            key(b"\r", new_link.encode())
            key(b"\x1b", b"MASC Collab")
            key(b"q", b"MASC Dashboard")
            assert old_link.encode() not in output[boundary:], "A's retained card leaked into B"
            assert late_link.encode() not in output[boundary:], "A's late issue repopulated B's card store"
            assert issued == [("a", "shared"), ("a", "late"), ("b", "fresh")], issued
            assert not any(path.startswith("/api/v1/play/invites/") for path, _ in requests), requests
            os.write(master, b"q")
        finally:
            late.release.set()

    h.run_terminal_scenario(executable,
        description="Collab workspace withdrawal retires stale confirmation and bearer cards",
        interact=interact, prepare_workspace=prepare, refresh=0.5, terminal_cols=300,
        http_fixtures={"/health": health, "/health?full=1": health,
                       "/api/v1/play/invites": h.RequestHttpResponse(inventory)},
        http_requests=requests)


if __name__ == "__main__":
    run(sys.argv[1])
