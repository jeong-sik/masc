"""Native PTY: retained pages stay separate from current browser actions."""
import hashlib
import json
import os
from pathlib import Path
import sys
import threading

import test_tui_keyboard_input as h


def run(binary, *, quit_from_history=False, disconnected=False):
    fixtures = h.keeper_runtime_http_fixtures()
    client = "11111111-1111-4111-8111-111111111111"
    current = "https://example.org/current"
    requests = []
    beta_entered = threading.Event()
    beta_release = threading.Event()
    beta_returned = threading.Event()

    def node(text):
        return {"nodeId": "text", "kind": "text", "tag": "p", "text": text,
                "color": "rgb(0,0,0)", "fontSize": 16, "fontWeight": "400", "whiteSpace": "normal",
                "rects": [{"x": 0, "y": 0, "width": 400, "height": 20}]}

    def scene(name):
        return {"schema": "masc.browser.scene.v1", "view": "content", "scope": None,
                "source": "live", "clientId": client, "tabId": 2, "documentId": name,
                "url": "https://example.org/" + name.lower(), "title": "Retained " + name,
                "chars": 16, "truncated": False, "nodes": [node("SAVED " + name.upper() + " CONTENT")],
                "viewport": {"width": 800, "height": 600, "scrollX": 0, "scrollY": 0}}

    rows = []
    for name in ["Alpha", "Beta"]:
        content = json.dumps(scene(name), separators=(",", ":"))
        raw = content.encode()
        digest = hashlib.sha256(raw).hexdigest()
        envelope = {"sha256": digest, "bytes": len(raw), "mime": "text/plain", "content": content}
        rows.append({"ts": 1789225500., "keeper": "alpha", "tool": "BrowserRead", "input": {},
                     "output": "truncated preview", "success": True, "execution_id": "exec-" + name,
                     "artifact_refs": [{"_blob": {"sha256": digest, "bytes": len(raw),
                         "mime": "application/vnd.masc.browser-scene+json", "preview": ""}}]})
        if name == "Beta":
            def beta(_body, response=envelope):
                beta_entered.set()
                assert beta_release.wait(10), "test never released older request"
                beta_returned.set()
                return 200, response
            fixtures["/api/v1/artifacts/" + digest] = h.RequestHttpResponse(beta)
        else:
            fixtures["/api/v1/artifacts/" + digest] = (200, envelope)
    fixtures["/api/v1/keepers/alpha/tool-calls?limit=100"] = (200, {
        "keeper": "alpha", "count": 2, "health": "ok", "entries": rows})
    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True,
        "data": {"clients": [] if disconnected else [{"clientId": client, "browser": "firefox"}]}})

    def read(body):
        request = json.loads(body)
        requests.append(("read", request))
        lane = request["lane"]
        return 200, {"ok": True, "data": {"source": lane, "clientId": client if lane == "live" else None, "elapsed_ms": 1.,
            "tabs": [{"id": 2, "title": "Current page", "url": current, "active": True}],
            "page": {"tabId": 2, "title": "Current page", "url": current,
                     "text": "CURRENT PAGE CONTENT", "chars": 20, "truncated": False}}}

    def read_scene(body):
        request = json.loads(body)
        requests.append(("scene", request))
        assert request["lane"] == "live" and request["tabId"] == 2
        assert request["view"] == "content"
        current_scene = scene("Current")
        current_scene["title"] = "Current scene"
        current_scene["elapsed_ms"] = 1.
        current_scene["nodes"] = [dict(node("CURRENT SCENE CONTROL"),
            kind="control", tag="button", clickable=True, editable=False, disabled=False)]
        return 200, {"ok": True, "data": current_scene}

    def effect(body):
        requests.append(("unexpected effect", json.loads(body)))
        return 500, {"error": "history must never send a browser action"}

    fixtures["/api/v1/dashboard/browser-lane/read"] = h.RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/scene"] = h.RequestHttpResponse(read_scene)
    for suffix in ["interact", "act", "screenshot", "session", "goto"]:
        fixtures["/api/v1/dashboard/browser-lane/" + suffix] = h.RequestHttpResponse(effect)

    def interact(process, fd, _slave, output, _base):
        try:
            h.palette_go(process, fd, output, b"go Keepers", b"alpha")
            h.palette_go(process, fd, output, b"go Browser Lane",
                         b"No active native browser connections" if disconnected else b"CURRENT PAGE CONTENT")
            h.send_and_wait(process, fd, output, b"h", b"retained observations")
            assert h.wait_for_fixture_event(process, fd, output, beta_entered, timeout=5), \
                "newest observation was never requested"
            # A slow newest page must not prevent switching to an earlier one.
            h.send_and_wait(process, fd, output, b"]", b"SAVED ALPHA CONTENT")
            beta_release.set()
            assert h.wait_for_fixture_event(process, fd, output, beta_returned, timeout=5)
            if quit_from_history:
                os.write(fd, b"Q")
                return
            count = len(requests)
            h.write_all(fd, output, b"\rsvgo\x0fR")
            frame = h.resize_and_wait(process, fd, output, rows=30, columns=101,
                needle=b"SAVED ALPHA CONTENT", controls=(h.FULL_REDRAW,))
            frame = h.resize_and_wait(process, fd, output, rows=30, columns=100,
                needle=b"SAVED ALPHA CONTENT", controls=(h.FULL_REDRAW,))
            assert b"SAVED BETA CONTENT" not in h.screen_text(frame), "late artifact replaced current selection"
            assert len(requests) == count, "history dispatched a current browser request"
            assert not any(kind == "unexpected effect" for kind, _ in requests)
            h.send_and_wait(process, fd, output, b"h", b"CURRENT PAGE CONTENT")
            h.send_and_wait(process, fd, output, b"a", b"CURRENT PAGE CONTENT")
            h.send_and_wait(process, fd, output, b"ghttps://example.org/history", b"https://example.org/history")
            h.send_and_wait(process, fd, output, b"\x1b", b"g:URL")
            frame = h.resize_and_wait(process, fd, output, rows=30, columns=101,
                needle=b"CURRENT PAGE CONTENT", controls=(h.FULL_REDRAW,))
            assert b"URL>" not in h.screen_text(frame), "Escape did not close the URL editor"
            h.send_and_wait(process, fd, output, b"l", b"CURRENT PAGE CONTENT")
            h.send_and_wait(process, fd, output, b"s", b"CURRENT SCENE CONTROL")
            h.send_and_wait(process, fd, output, b"h", b"SAVED BETA CONTENT")
            # History leaves Tab to the global ring, including when its
            # underlying browser pane could otherwise consume focus traversal.
            h.send_and_wait(process, fd, output, b"\t", b"MASC Overview")
            h.palette_go(process, fd, output, b"go Browser Lane", b"CURRENT PAGE CONTENT")
            h.send_and_wait(process, fd, output, b"l", b"CURRENT PAGE CONTENT")
            h.send_and_wait(process, fd, output, b"s", b"CURRENT SCENE CONTROL")
            h.send_and_wait(process, fd, output, b"h", b"SAVED BETA CONTENT")
            h.send_and_wait(process, fd, output, b"\x1b[Z", b"MASC Workspace")
            # Global navigation must release the hidden history's key ownership.
            h.palette_go(process, fd, output, b"go Overview", b"MASC Overview")
            os.write(fd, b"q")
        finally:
            beta_release.set()

    h.run_terminal_scenario(binary, description="retained browser observation isolation",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(str(Path(sys.argv[1]).resolve()))
    run(str(Path(sys.argv[1]).resolve()), quit_from_history=True, disconnected=True)
    print("Browser observation history: PASS")
