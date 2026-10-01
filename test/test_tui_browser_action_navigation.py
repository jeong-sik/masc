"""Select and act on observed browser targets beyond a long wrapped article.

Uses an isolated HTTP fixture and the real TUI; no website or Keeper is run.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import threading
import zlib

import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names, so without
# this a change to the drawn text below reaches main with no scenario run.
# The lane's drawn words ("Reading browser text and controls",
# "Enter:read region") are masc_tui_render.ml's; the palette row this types
# ("go Browser Lane") is masc_tui_types.ml's.
SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
)


def run(binary):
    client = "11111111-1111-4111-8111-111111111111"
    target = {"lane": "live", "clientId": client, "tabId": 2}
    url = "https://example.org/article"
    scenes, actions = [], []
    first_scene_release = threading.Event()
    fixtures = h.overview_event_http_fixtures()
    binary_digest = hashlib.sha256(Path(binary).read_bytes()).hexdigest()

    def record_terminal(label, output):
        # Preserve actual emitted frames through their last complete boundary.
        # Replaying the stream also retains cells from incremental frames.
        end = output.rfind(h.FRAME_END)
        assert end >= 0
        recording = bytes(output[:end + len(h.FRAME_END)])
        print("BROWSER_ACTION_PTY " + json.dumps({
            "label": label, "columns": 100, "rows": 30,
            "binary_sha256": binary_digest, "encoding": "zlib+base64",
            "pty": base64.b64encode(zlib.compress(recording)).decode(),
        }), flush=True)

    def node(identity, kind, text, **fields):
        return {"nodeId": identity, "kind": kind, "tag": "section" if kind == "region" else "p",
                "text": text, "rects": [{"x": 0, "y": 0, "width": 100, "height": 20}],
                "color": "rgb(0,0,0)", "fontSize": 16, "fontWeight": "400",
                "whiteSpace": "normal", "sourceContext": None, **fields}

    def control(identity, text, disabled=False, source=None):
        return node(identity, "control", text, clickable=True, editable=False, disabled=disabled,
                    sourceContext=source)

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
            nodes = [node("text", "text", f"SELECTED ARTICLE CONTENT reading {len(scenes)}")]
        else:
            nodes = [node("intro", "text", "LONG ARTICLE " + ("wrapped article content " * 180)),
                     control("first", "FIRST LINK"), control("disabled", "DISABLED LINK", True),
                     node("middle", "text", "Intervening text " * 180),
                     control("second", "SECOND LINK", source={
                         "schema": "masc.source.v1", "file": "src/article.tsx", "line": 7,
                         "column": 3, "kind": "element", "digest": "a" * 64})]
            if actions:
                nodes = [node("done", "text", "CLICK RESULT VERIFIED")]
        return 200, {"ok": True, "data": {"source": "live", "clientId": client, "tabId": 2,
            "elapsed_ms": 1, "schema": "masc.browser.scene.v1", "view": view, "scope": scope,
            "documentId": "document", "url": url, "title": "Article", "truncated": scope is not None,
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
            assert b"Source unavailable" not in h.screen_text(output)
            h.send_and_wait(process, fd, output, b"\t", b"[>5 button/link] SECOND LINK")
            assert b"src/article.tsx:7:3" in h.screen_text(output)
            h.send_and_wait(process, fd, output, b"\x1b[Z", b"[>2 button/link] FIRST LINK")
            assert b"src/article.tsx:7:3" not in h.screen_text(output)
            h.send_and_wait(process, fd, output, b"n", b"[>3 disabled] DISABLED LINK")
            h.send_and_wait(process, fd, output, b"\t", b"[>5 button/link] SECOND LINK")
            # Forward/backward action traversal wraps without losing the scene.
            h.send_and_wait(process, fd, output, b"\t", b"[>2 button/link] FIRST LINK")
            h.send_and_wait(process, fd, output, b"\x1b[Z", b"[>5 button/link] SECOND LINK")
            assert len(scenes) == 1 and not actions, "selection must not send browser requests"
            record_terminal("selected-action", output)
            h.send_and_wait(process, fd, output, b"\r", b"CLICK RESULT VERIFIED")
            assert len(scenes) == 2 and len(actions) == 1
            frame = h.send_and_wait(process, fd, output, b"v", b"Article body")
            assert b"Enter:read region" in h.screen_text(frame), frame
            h.send_and_wait(process, fd, output, b"\t", b"[>2 region")
            frame = h.send_and_wait(process, fd, output, b"\r", b"SELECTED ARTICLE CONTENT")
            # #36036 keeps the semantic scope context, so the scoped read names the
            # region role and label instead of the generic "Selected region".
            assert b"Selected main" in h.screen_text(frame), frame
            assert b"Article body" in h.screen_text(frame), frame
            clipboard = re.compile(rb"\x1b\]52;c;([A-Za-z0-9+/=]+)\x07")
            frame = h.send_and_wait(process, fd, output, b"y", clipboard)
            copied = json.loads(base64.b64decode(clipboard.search(frame).group(1), validate=True))
            assert {k: copied[k] for k in target} == target
            assert copied["view"] == "content" and copied["truncated"] is True
            assert copied["scope"] == {"documentId": "document", "nodeId": "article"}
            assert copied["nodeId"] == "text", "region and selected element must remain distinct"
            assert copied["viewport"] == {"width": 800, "height": 600, "scrollX": 0, "scrollY": 0}
            record_terminal("copied-region", output)
            focused = scenes[-1]
            # Identical text need not be emitted again by the differential
            # renderer. Require a new response revision to prove this refresh
            # completed while retaining its original region and target.
            refreshed_count = len(scenes) + 1
            h.send_and_wait(process, fd, output, b"r",
                            f"SELECTED ARTICLE CONTENT reading {refreshed_count}".encode())
            assert len(scenes) == refreshed_count
            assert scenes[-1] == focused and len(actions) == 1
            # No actionable node remains. Tab stays in the observed region.
            os.write(fd, b"\t")
            h.wait_for_terminal_input_consumed(_slave)
            h.resize_and_wait(process, fd, output, rows=30, columns=101,
                              needle=b"SELECTED ARTICLE CONTENT", controls=(h.FULL_REDRAW,))
            assert scenes[-1] == focused and len(actions) == 1
            # Retain an actionable region scene behind the picker. Tab must
            # use the existing Config-family surface cycle, not its hidden targets.
            h.send_and_wait(process, fd, output, b"v", b"Article body")
            chooser_start = len(output)
            h.send_and_wait(process, fd, output, b"b",
                            b"Choose browser \xc2\xb7 separate sessions do not share login")
            h.wait_for_output(process, fd, output, b"Zen", start=chooser_start, timeout=3.0)
            h.wait_for_output(process, fd, output, h.FRAME_END,
                              start=bytes(output).rfind(b"Zen", chooser_start), timeout=3.0)
            picker = h.screen_text(bytes(output))
            for option in (b"Zen", b"Stagehand Chromium", b"Independent Firefox/Zen"):
                assert option in picker, (option, picker)
            requests_before_picker_tab = (len(scenes), len(actions))
            h.send_and_wait(process, fd, output, b"\t", b"MASC Dashboard")
            assert (len(scenes), len(actions)) == requests_before_picker_tab
            os.write(fd, b"q")
        finally:
            first_scene_release.set()

    h.run_terminal_scenario(binary, description="browser action traversal and selection visibility",
                            interact=interact, http_fixtures=fixtures)


def run_session_lifecycle(binary, lane, source_key):
    fixtures = h.overview_event_http_fixtures()
    requests = []
    release = threading.Event()
    state = {"closed": False, "url": "https://example.org/session", "revision": 0}
    binary_digest = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {
        "ok": True, "data": {"clients": []}})

    def read(body):
        request = json.loads(body)
        requests.append(("read", request, state["closed"]))
        assert request["lane"] == lane
        if state["closed"]:
            return 200, {"ok": False, "error": "no_session"}
        state["revision"] += 1
        text = f"SESSION PAGE {state['revision']}\nREAD URL {state['url']}"
        return 200, {"ok": True, "data": {"source": lane, "clientId": None,
            "elapsed_ms": 1, "tabs": [{"id": 2, "title": "Session", "url": state["url"], "active": True}],
            "page": {"tabId": 2, "title": "Session", "url": state["url"],
                     "text": text, "chars": len(text), "truncated": False}}}

    def session(body):
        request = json.loads(body)
        requests.append(("session", request))
        assert request["lane"] == lane
        assert release.wait(10), "session progress was never released"
        state["closed"] = request["action"] == "close"
        return 200, {"ok": True}

    def goto(body):
        request = json.loads(body)
        requests.append(("goto", request))
        assert request["lane"] == lane
        assert release.wait(10), "navigation progress was never released"
        state["url"] = request["url"]
        return 200, {"ok": True}

    for verb, handler in (("read", read), ("session", session), ("goto", goto)):
        fixtures[f"/api/v1/dashboard/browser-lane/{verb}"] = h.RequestHttpResponse(handler)

    def record_terminal(label, output):
        end = output.rfind(h.FRAME_END)
        assert end >= 0
        recording = bytes(output[:end + len(h.FRAME_END)])
        print("BROWSER_SESSION_PTY " + json.dumps({
            "label": label, "lane": lane, "columns": 101, "rows": 30,
            "binary_sha256": binary_digest, "encoding": "zlib+base64",
            "pty": base64.b64encode(zlib.compress(recording)).decode(),
        }), flush=True)

    def release_and_wait(process, fd, output, needle):
        start = len(output)
        release.set()
        h.wait_for_output(process, fd, output, needle, start=start, timeout=3)
        needle_end = h.end_of_needle(output, needle, start)
        h.wait_for_output(process, fd, output, h.FRAME_END, start=needle_end, timeout=3)

    def interact(process, fd, _slave, output, _base):
        try:
            h.palette_go(process, fd, output, b"go Browser Lane", b"No active native browser connections")
            h.send_and_wait(process, fd, output, source_key, b"SESSION PAGE 1")
            h.send_and_wait(process, fd, output, b"x", f"Closing {lane} browser".encode())
            release.set()
            h.wait_for_output(process, fd, output, b"Browser session closed", start=0, timeout=3)
            h.resize_and_wait(process, fd, output, rows=30, columns=101,
                              needle=b"Browser session closed", controls=(h.FULL_REDRAW,))
            assert b"HTTP failed" not in h.screen_text(output)
            assert b"SESSION PAGE" not in h.screen_text(output), "closed session retained stale page text"
            record_terminal("closed", output)
            release.clear()
            next_revision = state["revision"] + 1
            h.send_and_wait(process, fd, output, b"o", f"Opening {lane} browser".encode())
            release_and_wait(process, fd, output, f"SESSION PAGE {next_revision}".encode())
            record_terminal("reopened", output)
            release.clear()
            h.send_and_wait(process, fd, output, b"g", b"URL>")
            h.send_and_wait(process, fd, output, b"\x15https://example.org/next\r",
                            f"Navigating {lane} browser".encode())
            # A cadence read can increment the revision before the URL draft
            # owns input. Only the read receipt for this destination proves
            # navigation completed; neither the composer nor old output can.
            release_and_wait(process, fd, output, b"READ URL https://example.org/next")
            assert state["url"] == "https://example.org/next"
            assert not [r for r in requests if r[0] == "read" and r[2]], \
                "successful close must not trigger a read against the closed session"
            assert [r[1]["action"] for r in requests if r[0] == "session"] == ["close", "open"]
            os.write(fd, b"q")
        finally:
            release.set()

    h.run_terminal_scenario(binary, description=f"{lane} browser close and reopen preserve truthful status",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(str(Path(sys.argv[1]).resolve()))
    for lane, source_key in (("automation", b"a"), ("stagehand", b"c")):
        run_session_lifecycle(str(Path(sys.argv[1]).resolve()), lane, source_key)
    print("Browser action navigation: PASS")
