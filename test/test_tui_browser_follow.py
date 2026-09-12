"""Keep one native TUI open as its selected browser page changes elsewhere.

Only the isolated HTTP fixture changes the page. No refresh key navigates or
refreshes the TUI after each change. This is a native PTY regression, not a
real-browser or Keeper execution proof.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import threading
import zlib

import test_tui_keyboard_input as h


def run(binary):
    client = "11111111-1111-4111-8111-111111111111"
    target = {"lane": "live", "clientId": client, "tabId": 2}
    state = {"channel": "alpha", "version": 1, "switch": False,
             "hold_next": False, "health_while_held": 0}
    lock = threading.Lock()
    held = threading.Event()
    release = threading.Event()
    subsequent_cadence = threading.Event()
    requests = []
    fixtures = h.overview_event_http_fixtures()
    digest = hashlib.sha256(Path(binary).read_bytes()).hexdigest()

    def health():
        with lock:
            if held.is_set() and not release.is_set():
                state["health_while_held"] += 1
                # The first health request can belong to the tick that started
                # this scene read. The next proves another tick ran while held.
                if state["health_while_held"] >= 2:
                    subsequent_cadence.set()
        return 200, {}

    fixtures["/health"] = health

    def node(identity, kind, text, **fields):
        return {"nodeId": identity, "kind": kind,
                "tag": "section" if kind == "region" else "p", "text": text,
                "rects": [{"x": 0, "y": 0, "width": 100, "height": 20}],
                "color": "rgb(0,0,0)", "fontSize": 16, "fontWeight": "400", "whiteSpace": "normal", **fields}

    def record(label, output):
        end = output.rfind(h.FRAME_END)
        assert end >= 0
        print("BROWSER_FOLLOW_PTY " + json.dumps({
            "label": label, "columns": 100, "rows": 30, "binary_sha256": digest,
            "encoding": "zlib+base64",
            "pty": base64.b64encode(zlib.compress(bytes(output[:end + len(h.FRAME_END)]))).decode(),
        }), flush=True)

    def read(body):
        request = json.loads(body)
        assert request["lane"] == "live" and request["clientId"] == client
        assert request.get("tabId", 2) == 2
        with lock:
            channel = state["channel"]
        text = "\n".join([channel.upper() + " TEXT READY"] +
                         [f"{channel.upper()} RAW LINE {i}" for i in range(1, 81)])
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "elapsed_ms": 1, "tabs": [{"id": 2, "title": channel.title(),
                "url": f"https://example.org/{channel}", "active": True}],
            "page": {"tabId": 2, "title": channel.title(), "url": f"https://example.org/{channel}",
                "text": text, "chars": len(text), "truncated": False}}}

    def scene(body):
        request = json.loads(body)
        assert {k: request[k] for k in target} == target
        with lock:
            if state["switch"] and request["view"] == "regions":
                state.update(channel="beta", version=1, switch=False)
            channel, version = state["channel"], state["version"]
            requests.append(dict(request))
            hold = state["hold_next"]
            state["hold_next"] = False
        if hold:
            held.set()
            assert release.wait(timeout=10.0), "test did not release scene response"
        view, scope = request["view"], request.get("scope")
        if scope:
            assert scope == {"documentId": channel, "nodeId": channel + "-messages"}, "stale scope reused"
            nodes = [node("message", "text", f"{channel.upper()} FOCUSED VERSION {version}")]
        elif view == "regions":
            nodes = [node("navigation", "region", "Navigation", role="navigation"),
                     node(channel + "-messages", "region", channel.title() + " messages", role="main")]
        else:
            nodes = [node("intro", "text", "ALPHA ARTICLE " + "long wrapped content " * 180),
                     node("first", "control", "FIRST ACTION", clickable=True, disabled=False, editable=False),
                     node("last", "control", f"LAST ACTION VERSION {version}", clickable=True, disabled=False, editable=False)]
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "tabId": 2, "elapsed_ms": 1, "schema": "masc.browser.scene.v1", "view": view,
            "scope": scope, "documentId": channel, "url": f"https://example.org/{channel}",
            "title": channel.title(), "truncated": False, "nodes": nodes,
            "viewport": {"width": 800, "height": 600, "scrollX": 0, "scrollY": 0}}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True, "data": {
        "clients": [{"clientId": client, "browser": "zen"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = h.RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/scene"] = h.RequestHttpResponse(scene)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go Browser Lane", b"ALPHA TEXT READY")
        h.send_and_wait(process, fd, output, b"s", b"ALPHA ARTICLE")
        h.send_and_wait(process, fd, output, b"\t", b"[>2 button/link] FIRST ACTION")
        h.send_and_wait(process, fd, output, b"\t", b"[>3 button/link] LAST ACTION VERSION 1")
        start = len(output)
        with lock:
            state["version"] = 2
        try:
            h.wait_for_output(process, fd, output, b"[>3 button/link] LAST ACTION VERSION 2", start=start, timeout=3.0)
        except AssertionError:
            record("external-change-not-followed", output)
            raise
        record("same-page-selection-retained", output)

        with lock:
            state["hold_next"] = True
        try:
            assert h.wait_for_fixture_event(process, fd, output, held, timeout=3.0)
            h.send_and_wait(process, fd, output, b"\x1b[Z", b"[>2 button/link] FIRST ACTION")
            assert h.wait_for_fixture_event(process, fd, output, subsequent_cadence, timeout=3.0)
            h.send_and_wait(process, fd, output, b"\t", b"[>3 button/link] LAST ACTION VERSION 2")
            record("operator-input-during-slow-refresh", output)
        finally:
            release.set()

        h.send_and_wait(process, fd, output, b"v", b"Alpha messages")
        h.send_and_wait(process, fd, output, b"\t", b"[>2 region")
        h.send_and_wait(process, fd, output, b"\r", b"ALPHA FOCUSED VERSION 2")
        start = len(output)
        with lock:
            state["version"] = 3
        h.wait_for_output(process, fd, output, b"ALPHA FOCUSED VERSION 3", start=start, timeout=3.0)
        record("same-page-scope-retained", output)

        start = len(output)
        with lock:
            state["switch"] = True
        h.wait_for_output(process, fd, output, b"Beta messages", start=start, timeout=3.0)
        # Repaint from the actual final state, including the tab header. No r.
        h.resize_and_wait(process, fd, output, rows=30, columns=101,
            needle=b"Beta messages", controls=(h.FULL_REDRAW,))
        frame = h.resize_and_wait(process, fd, output, rows=30, columns=100,
            needle=b"Beta messages", controls=(h.FULL_REDRAW,))
        text = h.screen_text(frame)
        assert b"Beta" in text and b"https://example.org/beta" in text
        assert b"ALPHA TEXT READY" not in text and b"ALPHA FOCUSED" not in text
        record("changed-document-current-regions", output)
        h.send_and_wait(process, fd, output, b"\t", b"[>2 region")
        h.send_and_wait(process, fd, output, b"\r", b"BETA FOCUSED VERSION 1")
        # Plain text is a new read of Beta, never the cached initial Alpha.
        h.send_and_wait(process, fd, output, b"s", b"BETA TEXT READY")
        h.send_and_wait(process, fd, output, b"jjjjj", b"BETA RAW LINE 5")
        h.resize_and_wait(process, fd, output, rows=30, columns=101,
            needle=b"BETA RAW LINE 5", controls=(h.FULL_REDRAW,))
        frame = h.resize_and_wait(process, fd, output, rows=30, columns=100,
            needle=b"BETA RAW LINE 5", controls=(h.FULL_REDRAW,))
        assert b"BETA TEXT READY" not in h.screen_text(frame), "raw text did not scroll"
        start = len(output)
        with lock:
            state["channel"] = "gamma"
        h.wait_for_output(process, fd, output, b"GAMMA TEXT READY", start=start, timeout=3.0)
        h.resize_and_wait(process, fd, output, rows=30, columns=101,
            needle=b"GAMMA TEXT READY", controls=(h.FULL_REDRAW,))
        frame = h.resize_and_wait(process, fd, output, rows=30, columns=100,
            needle=b"GAMMA TEXT READY", controls=(h.FULL_REDRAW,))
        text = h.screen_text(frame)
        assert b"https://example.org/gamma" in text and b"GAMMA TEXT READY" in text
        assert b"BETA RAW LINE" not in text
        record("external-raw-navigation-resets-scroll", output)
        with lock:
            assert any(r.get("scope") == {"documentId": "alpha", "nodeId": "alpha-messages"} for r in requests)
            assert any(r.get("scope") == {"documentId": "beta", "nodeId": "beta-messages"} for r in requests)
        os.write(fd, b"q")

    h.run_terminal_scenario(binary, description="Browser Lane follows external page changes",
                            interact=interact, refresh=0.5, http_fixtures=fixtures)


if __name__ == "__main__":
    run(str(Path(sys.argv[1]).resolve()))
    print("Browser Lane follow: PASS")
