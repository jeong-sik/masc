"""Select and act on observed browser targets beyond a long wrapped article.

Uses an isolated HTTP fixture and the real TUI; no website or Keeper is run.
"""
import json
import os
from pathlib import Path
import sys
import threading

import test_tui_keyboard_input as h


def run(binary):
    client = "11111111-1111-4111-8111-111111111111"
    target = {"lane": "live", "clientId": client, "tabId": 2}
    url = "https://example.org/article"
    scenes, actions = [], []
    first_scene_release = threading.Event()
    fixtures = h.overview_event_http_fixtures()

    def node(identity, kind, text, **fields):
        return {"nodeId": identity, "kind": kind, "tag": "section" if kind == "region" else "p",
                "text": text, "rects": [{"x": 0, "y": 0, "width": 100, "height": 20}],
                "color": "rgb(0,0,0)", "fontSize": 16, "fontWeight": "400",
                "whiteSpace": "normal", **fields}

    def control(identity, text, disabled=False):
        return node(identity, "control", text, clickable=True, editable=False, disabled=disabled)

    def read(_body):
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "elapsed_ms": 1, "tabs": [{"id": 2, "title": "Article", "url": url, "active": True}],
            "page": {"tabId": 2, "title": "Article", "url": url, "text": "ARTICLE READY",
                     "chars": 13, "truncated": False}}}

    def scene(body):
        request = json.loads(body)
        assert {k: request[k] for k in target} == target
        scenes.append(request)
        if len(scenes) == 1:
            first_scene_release.wait(timeout=30)
        view, scope = request["view"], request.get("scope")
        if view == "regions":
            nodes = [node("navigation", "region", "Navigation", role="navigation"),
                     node("article", "region", "Article body", role="main")]
        elif scope is not None:
            assert scope == {"documentId": "document", "nodeId": "article"}
            nodes = [node("text", "text", "SELECTED ARTICLE CONTENT")]
        else:
            nodes = [node("intro", "text", "LONG ARTICLE " + ("wrapped article content " * 180)),
                     control("first", "FIRST LINK"), control("disabled", "DISABLED LINK", True),
                     node("middle", "text", "Intervening text " * 180),
                     control("second", "SECOND LINK")]
            if actions:
                nodes = [node("done", "text", "CLICK RESULT VERIFIED")]
        return 200, {"ok": True, "data": {"source": "live", "clientId": client, "tabId": 2,
            "elapsed_ms": 1, "schema": "masc.browser.scene.v1", "view": view, "scope": scope,
            "documentId": "document", "url": url, "title": "Article", "truncated": False,
            "viewport": {"width": 800, "height": 600, "scrollX": 0, "scrollY": 0}, "nodes": nodes}}

    def click(body):
        request = json.loads(body)
        assert request == dict(target, action="click", documentId="document",
                               nodeId="second", expectedUrl=url)
        actions.append(request)
        return 200, {"ok": True, "data": {"clicked": True}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True, "data": {
        "clients": [{"clientId": client, "browser": "zen"}]}})
    for verb, handler in (("read", read), ("scene", scene), ("interact", click)):
        fixtures[f"/api/v1/dashboard/browser-lane/{verb}"] = h.RequestHttpResponse(handler)

    def interact(process, fd, _slave, output, _base):
        try:
            h.palette_go(process, fd, output, b"go Browser Lane", b"ARTICLE READY")
            h.send_and_wait(process, fd, output, b"s", b"Reading browser text and controls")
            os.write(fd, b"\t")
            h.wait_for_terminal_input_consumed(_slave)
            h.resize_and_wait(process, fd, output, rows=30, columns=101,
                              needle=b"Reading browser text and controls", controls=(h.FULL_REDRAW,))
            h.resize_and_wait(process, fd, output, rows=30, columns=100,
                              needle=b"Reading browser text and controls", controls=(h.FULL_REDRAW,))
            first_scene_release.set()
            h.wait_for_output(process, fd, output, b"LONG ARTICLE", start=0, timeout=3)
            # Each marker must reach the body, not only the selected-element title.
            h.send_and_wait(process, fd, output, b"\t", b"[>2 button/link] FIRST LINK")
            h.send_and_wait(process, fd, output, b"\t", b"[>5 button/link] SECOND LINK")
            h.send_and_wait(process, fd, output, b"\x1b[Z", b"[>2 button/link] FIRST LINK")
            h.send_and_wait(process, fd, output, b"n", b"[>3 disabled] DISABLED LINK")
            h.send_and_wait(process, fd, output, b"\t", b"[>5 button/link] SECOND LINK")
            # Forward/backward action traversal wraps without losing the scene.
            h.send_and_wait(process, fd, output, b"\t", b"[>2 button/link] FIRST LINK")
            h.send_and_wait(process, fd, output, b"\x1b[Z", b"[>5 button/link] SECOND LINK")
            assert len(scenes) == 1 and not actions, "selection must not send browser requests"
            h.send_and_wait(process, fd, output, b"\r", b"CLICK RESULT VERIFIED")
            assert len(scenes) == 2 and len(actions) == 1
            frame = h.send_and_wait(process, fd, output, b"v", b"Article body")
            assert b"Enter:read region" in h.screen_text(frame), frame
            h.send_and_wait(process, fd, output, b"\t", b"[>2 region")
            frame = h.send_and_wait(process, fd, output, b"\r", b"SELECTED ARTICLE CONTENT")
            assert b"Selected region" in h.screen_text(frame), frame
            focused = scenes[-1]
            h.send_and_wait(process, fd, output, b"r", b"SELECTED ARTICLE CONTENT")
            assert scenes[-1] == focused and len(actions) == 1
            # No actionable node remains. Tab stays in the observed region.
            os.write(fd, b"\t")
            h.wait_for_terminal_input_consumed(_slave)
            h.resize_and_wait(process, fd, output, rows=30, columns=101,
                              needle=b"SELECTED ARTICLE CONTENT", controls=(h.FULL_REDRAW,))
            assert scenes[-1] == focused and len(actions) == 1
            os.write(fd, b"q")
        finally:
            first_scene_release.set()

    h.run_terminal_scenario(binary, description="browser action traversal and selection visibility",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(str(Path(sys.argv[1]).resolve()))
    print("Browser action navigation: PASS")
