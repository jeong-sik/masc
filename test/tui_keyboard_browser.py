from __future__ import annotations

import base64
import json
import os
import termios
import threading
from collections.abc import Callable
from pathlib import Path

from tui_keyboard_chat import (
    GRAPHICS_SUPPORTED_REPLY,
    IMAGE_NAME,
    seed_image_workspace,
)
from tui_keyboard_harness import (
    CSI_RE,
    FRAME_END,
    FULL_REDRAW,
    HttpResponse,
    RequestHttpResponse,
    SequencedHttpResponse,
    drain_until_quiet,
    end_of_needle,
    overview_event_http_fixtures,
    palette_go,
    read_available,
    resize_and_wait,
    run_terminal_scenario,
    screen_text,
    send_and_wait,
    wait_for_fixture_event,
    wait_for_fixture_state,
    wait_for_output,
    wait_for_terminal_input_consumed,
    write_all,
)


def run_browser_client_picker_regression(executable: str) -> None:
    fixtures = overview_event_http_fixtures()
    firefox = "11111111-1111-4111-8111-111111111111"
    bidi = "22222222-2222-4222-8222-222222222222"
    active = [
        {"clientId": firefox, "browser": "firefox", "transport": "web_extension"},
        {"clientId": bidi, "browser": "firefox", "transport": "webdriver_bidi"},
    ]
    reads: list[dict[str, object]] = []

    def read(body: bytes) -> HttpResponse:
        request = json.loads(body)
        reads.append(request)
        client = request.get("clientId")
        if client not in [row["clientId"] for row in active]:
            return 409, {"ok": False, "error": "client_not_connected"}
        text = "BiDi selected page" if client == bidi else "Firefox selected page"
        return 200, {"ok": True, "data": {
            "source": "live", "clientId": client, "elapsed_ms": 1.0,
            "tabs": [{"id": 2, "title": text, "url": "https://example.org/", "active": True}],
            "page": {"tabId": 2, "title": text, "url": "https://example.org/",
                     "text": text, "chars": len(text), "truncated": False}}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = SequencedHttpResponse([
        (200, {"ok": True, "data": {"clients": list(active)}}),
        (200, {"ok": True, "data": {"clients": list(active)}}),
        (200, {"ok": True, "data": {"clients": [active[1]]}}),
    ])
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)

    def interact(process, master_fd, slave_fd, output, _base):
        palette_go(process, master_fd, output, b"go Browser Lane", b"Choose browser \xc2\xb7 separate sessions do not share login")
        # The title names the chosen connection the same way a row does, so
        # the row is recognised by the part only a row carries.
        bidi_row = "Firefox · BiDi · existing login".encode()
        wait_for_output(process, master_fd, output, bidi_row, start=0, timeout=3.0)
        if reads:
            raise AssertionError("unselected multi-client view sent a browser read")
        os.write(master_fd, b"j")
        wait_for_terminal_input_consumed(slave_fd)
        send_and_wait(process, master_fd, output, b"\r", b"BiDi selected page")
        if reads != [{"lane": "live", "clientId": bidi}]:
            raise AssertionError("BiDi choice did not pin its client ID")
        read_available(master_fd, output)
        chooser_start = len(output)
        send_and_wait(process, master_fd, output, b"b", b"Choose browser \xc2\xb7 separate sessions do not share login")
        # b clears the displayed inventory until discovery settles. Require a
        # row from this request, not Firefox text in an earlier chooser frame.
        wait_for_output(process, master_fd, output, bidi_row, start=chooser_start, timeout=3.0)
        wait_for_output(process, master_fd, output, FRAME_END,
                        start=bytes(output).rfind(bidi_row, chooser_start), timeout=3.0)
        picker = screen_text(bytes(output))
        for option in ("Firefox · WebExtension · existing login".encode(), bidi_row,
                       b"Stagehand Chromium", b"Independent Firefox/Zen",
                       "WebExtension: no hover, drag · BiDi serves them".encode()):
            if option not in picker:
                raise AssertionError(f"browser picker omitted {option!r}: {picker!r}")
        send_and_wait(process, master_fd, output, b"\r", b"Firefox selected page")
        if reads[-1] != {"lane": "live", "clientId": firefox}:
            raise AssertionError("browser switch reused the old browser's tab ID")
        active[:] = [active[1]]
        send_and_wait(process, master_fd, output, b"r", b"Selected browser disconnected")
        if len(reads) != 2:
            raise AssertionError("stale Firefox pin silently rebound to the remaining BiDi client")
        if b"Firefox selected page" in screen_text(bytes(output)):
            raise AssertionError("disconnected browser content remained under the chooser")
        send_and_wait(process, master_fd, output, b"\r", b"BiDi selected page")
        if reads[-1] != {"lane": "live", "clientId": bidi}:
            raise AssertionError("explicit reconnect carried the stale tab ID")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
        os.write(master_fd, b"q")

    run_terminal_scenario(executable, description="Browser client pinning and disconnected selection",
        interact=interact, http_fixtures=fixtures)


def run_browser_scene_regression(executable: str) -> None:
    fixtures = overview_event_http_fixtures()
    client = "11111111-1111-4111-8111-111111111111"
    target = {"lane": "live", "clientId": client, "tabId": 2}
    url = "https://example.org/scene"
    scenes, actions, scrolls, scene_viewports = [], [], [], []
    scroll_y = [0]
    # J and K are ignored while a browser read is in flight, so the scoped
    # refresh is held until its loading row is drawn and released before them.
    hold_refresh = {"armed": False}
    refresh_seen, refresh_release = threading.Event(), threading.Event()

    def node(identity, kind, text):
        result = {"nodeId": identity, "kind": kind, "tag": "button" if kind == "control" else "p",
            "text": text, "rects": [{"x": 0, "y": 0, "width": 100, "height": 20}],
            "color": "rgb(0,0,0)", "fontSize": 16, "fontWeight": "400", "whiteSpace": "normal",
            "sourceContext": None}
        if kind == "control":
            result.update(clickable=True, editable=False, disabled=False)
        return result

    def read(_body):
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "elapsed_ms": 12.5, "tabs": [{"id": 2, "title": "scene", "url": url, "active": True}],
            "page": {"tabId": 2, "title": "scene", "url": url,
                "text": "scene reader ready", "chars": 18, "truncated": False}}}

    def scene(body):
        request = json.loads(body)
        if hold_refresh["armed"]:
            hold_refresh["armed"] = False
            refresh_seen.set()
            refresh_release.wait(10.0)
        scenes.append(request)
        assert {k:request[k] for k in target} == target, "scene read lost client/tab ownership"
        changed = bool(actions)
        view = request.get("view")
        scope = request.get("scope")
        assert view in ("content","regions")
        if "expectedUrl" in request:
            assert request["expectedUrl"] == url
        region = dict(node("channel-region","region","Channel messages"),role="main")
        if view == "regions":
            nodes = [region]
        elif scope:
            assert scope == {"documentId":"document-after","nodeId":"channel-region"}
            nodes = [node("message","text","SCOPED CHANNEL CONTENT")]
        else:
            nodes = [node("body", "text", "SCENE CLICK VERIFIED" if changed else "SCENE BEFORE CLICK"),
                node("first-control", "control", "First action"),
                node("second-control", "control", "Second action"),
                node("image", "raster", "Scene illustration")]
        viewport = {"width": 800, "height": 600, "scrollX": 0, "scrollY": scroll_y[0]}
        scene_viewports.append(viewport)
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "tabId": 2, "elapsed_ms": 13.0, "schema": "masc.browser.scene.v1", "view":view, "scope":scope,
            "documentId": "document-after" if changed else "document-before",
            "url": url, "title": "scene", "truncated": False,
            "viewport": viewport,
            "nodes": nodes}}

    def click(body):
        request = json.loads(body)
        assert request == dict(target, action="click", documentId="document-before",
            nodeId="second-control", expectedUrl=url), "click lost the selected observed reference"
        actions.append(request)
        return 200, {"ok": True, "data": {"clicked": True}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True,
        "data": {"clients": [{"clientId": client, "browser": "zen", "transport": "web_extension"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/scene"] = RequestHttpResponse(scene)
    def interact_request(body):
        request = json.loads(body)
        if request.get("action") == "scroll":
            assert request == dict(target, expectedUrl=url, action="scroll", x=0, y=request["y"])
            assert request["y"] in (600, -600)
            scrolls.append(request)
            scroll_y[0] = max(0, scroll_y[0] + request["y"])
            return 200, {"ok": True, "data": {"scrollY": scroll_y[0]}}
        return click(body)

    fixtures["/api/v1/dashboard/browser-lane/interact"] = RequestHttpResponse(interact_request)

    def interact(process, master, _slave, output, _base):
        palette_go(process, master, output, b"go Browser Lane", b"scene reader ready")
        frame = send_and_wait(process, master, output, b"s", b"SCENE BEFORE CLICK")
        visible = screen_text(frame)
        # Source-context selection includes text and raster observations,
        # not only clickable controls. Preserve their document order.
        for text in (b"[>1] SCENE BEFORE CLICK", b"[2 button/link] First action",
                     b"[3 button/link] Second action",
                     "[4 image · Ctrl-O] Scene illustration".encode()):
            assert text in visible, f"scene projection missing {text!r}"
        send_and_wait(process, master, output, b"n", b"[>2 button/link] First action")
        send_and_wait(process, master, output, b"n", b"[>3 button/link] Second action")
        send_and_wait(process, master, output, b"p", b"[>2 button/link] First action")
        send_and_wait(process, master, output, b"n", b"[>3 button/link] Second action")
        assert len(scenes) == 1 and not actions, "selection triggered a browser effect"
        send_and_wait(process, master, output, b"\r", b"SCENE CLICK VERIFIED")
        assert len(actions) == 1 and len(scenes) == 2, "click was not followed by one fresh scene"
        # The semantic main shortcut first observes the landmark map, then
        # focuses the unique main region without a guessed selector.
        send_and_wait(process, master, output, b"m", b"Channel messages")
        assert scenes[-1]["view"] == "regions" and len(actions)==1
        send_and_wait(process, master, output, b"m", b"SCOPED CHANNEL CONTENT")
        assert scenes[-1]["scope"] == {"documentId":"document-after","nodeId":"channel-region"}
        focused = scenes[-1]
        # These three keys are answered on the wire and, by design, leave the
        # screen as it stands: the refresh is asserted to return the same scene
        # just below, and the scroll moves the page the scene was read from
        # rather than the rows drawn from it. An unchanged frame is written as
        # nothing, so each is waited for where its effect actually lands.
        def press_and_await(key: bytes, ready: Callable[[], bool], what: str) -> None:
            read_available(master, output)
            write_all(master, output, key)
            # Five seconds, as wait_for_fixture_event is given elsewhere: a
            # scroll is two round trips, the move and the re-read after it.
            if not wait_for_fixture_state(
                process, master, output, ready, timeout=5.0
            ):
                raise AssertionError(f"{key!r} did not reach the fixture: {what}")

        def scrolled(sent: int, read: int) -> Callable[[], bool]:
            return lambda: len(scrolls) > sent and len(scene_viewports) > read

        def settled(loading: bytes, what: str) -> None:
            if not wait_for_fixture_state(process, master, output,
                    lambda: loading not in screen_text(bytes(output)), timeout=5.0):
                raise AssertionError(f"{what} was still in flight: {screen_text(bytes(output))!r}")

        scoped = len(scenes)
        region_loading = "Reading selected page region…".encode()
        read_available(master, output)
        drawn_from = len(output)
        hold_refresh["armed"] = True
        write_all(master, output, b"r")
        try:
            if not wait_for_fixture_event(process, master, output, refresh_seen, timeout=5.0):
                raise AssertionError("b'r' did not reach the fixture: a scoped refresh")
            wait_for_output(process, master, output, region_loading, start=drawn_from, timeout=5.0)
        finally:
            refresh_release.set()
        settled(region_loading, "the scoped refresh")
        assert len(scenes) > scoped and scenes[-1] == focused and len(actions)==1, \
            "scoped refresh widened or caused an effect"
        press_and_await(b"J", scrolled(len(scrolls), len(scene_viewports)), "a scroll and its re-read")
        assert scrolls[-1]["y"] == 600 and scene_viewports[-1]["scrollY"] == 600
        settled("Scrolling page and refreshing scene…".encode(), "the scroll's re-read")
        press_and_await(b"K", scrolled(len(scrolls), len(scene_viewports)), "a scroll and its re-read")
        assert scrolls[-1]["y"] == -600 and scene_viewports[-1]["scrollY"] == 0
        send_and_wait(process, master, output, b"\x1b", b"MASC Dashboard")
        os.write(master, b"q")

    run_terminal_scenario(executable, description="Browser scene text, selection and observed click refresh",
        interact=interact, http_fixtures=fixtures)


def run_browser_viewport_regression(executable: str, *, cell_geometry: bool = True) -> None:
    fixtures = overview_event_http_fixtures()
    client = "11111111-1111-4111-8111-111111111111"
    captures, actions = [], []
    png = [""]
    changed = [False]
    blocked, release = threading.Event(), threading.Event()
    target = {"lane": "live", "clientId": client, "tabId": 2}
    url = "https://example.org/"

    def prepare(base):
        seed_image_workspace(base)
        png[0] = base64.b64encode(Path(base, IMAGE_NAME).read_bytes()).decode()

    def read(body):
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "elapsed_ms": 12.5, "tabs": [{"id": 2, "title": "owned", "url": url, "active": True}],
            "page": {"tabId": 2, "title": "owned", "url": url,
                "text": "owned browser body", "chars": 18, "truncated": False}}}

    def screenshot(body):
        request = json.loads(body)
        captures.append(request)
        assert request == target, "viewport capture lost its explicit target"
        return 200, {"ok": True, "data": {"source": "live", "clientId": client,
            "tabId": 2, "title": "owned", "url": url + "changed" if changed[0] else url,
            "mimeType": "image/png", "data": png[0], "viewport": {"documentId":"fixture","width":800,"height":600,"scrollX":0,"scrollY":0}, "elapsed_ms": 13.0}}

    def scroll(body):
        request = json.loads(body)
        actions.append(request)
        expected_point = {"x":0.5,"y":0.5} if len(actions)==1 or not cell_geometry else {"x":9.5/60,"y":6.5/30}
        assert request == dict(target, expectedUrl=url, action="scroll_at", x=0, y=120,
            point=expected_point,viewport={"documentId":"fixture","width":800,"height":600,"scrollX":0,"scrollY":0})
        if len(actions) == 2:
            blocked.set()
            if not release.wait(timeout=10):
                return 504, {"ok": False, "error": "fixture timeout"}
        return 200, {"ok": True, "data": {"scrollY": len(actions) * 120}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True,
        "data": {"clients": [{"clientId": client, "browser": "zen", "transport": "web_extension"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/screenshot"] = RequestHttpResponse(screenshot)
    fixtures["/api/v1/dashboard/browser-lane/interact"] = RequestHttpResponse(scroll)

    def interact(process, master, slave, output, _base):
        def image_input(data: bytes) -> bytes:
            # draw_image writes its own image layer and footer, without the
            # Frame_presenter FRAME_END emitted by ordinary text frames.
            read_available(master, output)
            start = len(output)
            os.write(master, data)
            wait_for_output(process, master, output, b"a=T", start=start, timeout=3)
            image_end = end_of_needle(output, b"a=T", start)
            # Include the wheel hint before checking pane/center fallback.
            # Esc: back is only the beginning of the footer.
            footer = b"j/k:center"
            wait_for_output(process, master, output, footer, start=image_end, timeout=3)
            return bytes(output[start:end_of_needle(output, footer, image_end)])

        palette_go(process, master, output, b"go Browser Lane", b"owned browser body")
        initial_image = image_input(b"\x0f")
        if not cell_geometry:
            assert b"wheel:center" in initial_image, "missing center-wheel fallback hint"
        image_input(b"j")
        assert len(actions) == 1 and len(captures) == 2
        # Global shortcuts and pasted text belong to the visible viewport.
        os.write(master, b"a\x1b[200~hidden-draft\x1b[201~")
        wait_for_terminal_input_consumed(slave)
        image_input(b"r")
        assert len(actions) == 1 and len(captures) == 3
        resize_and_wait(process, master, output, rows=35, columns=110, needle=b"Esc: back")
        assert len(captures) == 3, "resize must redraw cached bytes without browser effects"
        os.write(master, b"\x1b[<65;10;10M")
        assert wait_for_fixture_event(process, master, output, blocked, timeout=3)
        os.write(master, b"jr")
        wait_for_terminal_input_consumed(slave)
        send_and_wait(process, master, output, b"\x1b", b"Scrolling selected browser viewport")
        read_available(master, output)
        start = len(output)
        release.set()
        wait_for_output(process, master, output, b"Read 12.5 ms", start=start, timeout=3)
        assert b"a=T" not in output[start:], "late frame reopened a closed viewport"
        assert len(actions) == 2 and len(captures) == 4, "busy input was queued or replayed"
        image_input(b"\x0f")
        changed[0] = True
        # The long ownership error is clipped to the viewport width. Its
        # visible prefix plus the assertions below establish refusal without
        # requiring text that is correctly outside the rendered frame.
        restored = send_and_wait(process, master, output, b"r", b"Cause: screenshot source")
        assert FULL_REDRAW in restored, "async image dismissal reused the cleared text frame"
        visible = screen_text(restored[restored.rfind(FULL_REDRAW):])
        for row in (b"MASC Browser Lane", b"HTTP failed", b"Cause: screenshot source",
                    b"owned browser body", b"b:choose browser"):
            assert row in visible, f"async image dismissal did not restore {row!r}"
        assert b"Read/action failed" not in visible, "Browser Lane repeated the failure verdict"
        assert b"Esc: back" not in visible, "viewport footer remained after async dismissal"
        assert len(captures) == 6
        send_and_wait(process, master, output, b"\x1b", b"MASC Dashboard")
        os.write(master, b"q")

    try:
        run_terminal_scenario(executable,
            description=("Browser visual viewport input and late frame ownership" if cell_geometry
                else "Browser visual viewport input when the terminal reports no cell size"),
            interact=interact, http_fixtures=fixtures, prepare_workspace=prepare,
            preload_input=(b"\x1b[6;20;10t" if cell_geometry else b"")+GRAPHICS_SUPPORTED_REPLY)
    finally:
        release.set()


def run_browser_pointer_regression(executable: str) -> None:
    fixtures = overview_event_http_fixtures()
    client = "11111111-1111-4111-8111-111111111111"
    actions, captures, png = [], [], [""]
    viewport = {"documentId":"fixture","width":800,"height":600,"scrollX":0,"scrollY":0}
    url = "https://example.org/"

    def prepare(base):
        seed_image_workspace(base)
        png[0] = base64.b64encode(Path(base, IMAGE_NAME).read_bytes()).decode()

    def read(body):
        request = json.loads(body)
        return 200, {"ok":True,"data":{"source":request["lane"],"clientId":request.get("clientId"),
            "elapsed_ms":0,"tabs":[{"id":2,"title":"owned","url":url,"active":True}],
            "page":{"tabId":2,"title":"owned","url":url,"text":"pointer fixture","chars":15,"truncated":False}}}

    def screenshot(body):
        request = json.loads(body)
        captures.append(request)
        return 200, {"ok":True,"data":{"source":request["lane"],"clientId":request.get("clientId"),
            "tabId":2,"title":"owned","url":url,"mimeType":"image/png","data":png[0],"viewport":viewport,"elapsed_ms":0}}

    def act(body):
        request = json.loads(body)
        assert request["lane"] == "automation" and request["tabId"] == 2
        assert "clientId" not in request and request["expectedUrl"] == url
        assert request["viewport"] == viewport
        actions.append(request)
        return 200, {"ok":True,"data":{}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200,{"ok":True,"data":{"clients":[{"clientId":client,"browser":"firefox","transport":"web_extension"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/screenshot"] = RequestHttpResponse(screenshot)
    fixtures["/api/v1/dashboard/browser-lane/interact"] = RequestHttpResponse(act)

    def interact(process, master, slave, output, _base):
        palette_go(process, master, output, b"go Browser Lane", b"pointer fixture")
        send_and_wait(process, master, output, b"a", b"pointer fixture")
        def image_input(data):
            read_available(master, output)
            start = len(output)
            os.write(master, data)
            wait_for_output(process, master, output, b"Esc: back", start=start, timeout=3)
            return bytes(output[start:])
        image = image_input(b"\x0f")
        assert b"f=100,a=T,r=25," in image, "fullscreen screenshot must use all 30 physical terminal rows"
        # Caption clicks are consumed without dispatch; no double action on press.
        os.write(master, b"\x1b[<0;2;1M\x1b[<0;2;1m")
        wait_for_terminal_input_consumed(slave)
        assert not actions
        image_input(b"\x1b[<0;2;5M\x1b[<0;2;5m")
        assert len(actions)==1 and actions[0]["action"]=="click_at"
        # 30x100 terminal, 10x20 cells, square PNG: 25 rows x 50 columns,
        # after the three caption rows. Mouse reports target cell centers.
        assert actions[0]["point"] == {"x":0.03,"y":0.06}, actions[0]
        image_input(b"\x1b[<0;2;5M\x1b[<0;5;8m")
        assert len(actions)==2 and actions[1]["action"]=="drag"
        assert actions[1]["from"] == {"x":0.03,"y":0.06}, actions[1]["from"]
        assert actions[1]["to"] == {"x":0.09,"y":0.18}, actions[1]["to"]
        assert len(captures)==3
        send_and_wait(process, master, output, b"\x1b", b"pointer fixture")
        send_and_wait(process, master, output, b"\x1b", b"MASC Dashboard")
        os.write(master,b"q")

    run_terminal_scenario(executable, description="Browser screenshot mouse click and drag routing",
        interact=interact,http_fixtures=fixtures,prepare_workspace=prepare,
        preload_input=b"\x1b[6;20;10t"+GRAPHICS_SUPPORTED_REPLY)


def run_browser_unserved_gesture_regression(executable: str, *, bidi_listed: bool = False) -> None:
    """A drag on a live WebExtension screenshot is not sent, and says why.

    The terminal is 80 columns wide: the reason and the next step have to be
    readable there. The reason outlives the lane's own refresh and goes with
    the operator's next input. With a BiDi connection listed the next step is
    the picker; with none it is where attaching one is written.
    """
    fixtures = overview_event_http_fixtures()
    extension = "11111111-1111-4111-8111-111111111111"
    bidi = "22222222-2222-4222-8222-222222222222"
    connected = [{"clientId": extension, "browser": "firefox", "transport": "web_extension"}]
    if bidi_listed:
        connected.append({"clientId": bidi, "browser": "firefox", "transport": "webdriver_bidi"})
    actions, png = [], [""]
    clicked, captured_after_click = threading.Event(), threading.Event()
    refused, read_after_refusal = threading.Event(), threading.Event()
    viewport = {"documentId":"fixture","width":800,"height":600,"scrollX":0,"scrollY":0}
    url = "https://example.org/"

    def prepare(base):
        seed_image_workspace(base)
        png[0] = base64.b64encode(Path(base, IMAGE_NAME).read_bytes()).decode()

    def read(body):
        request = json.loads(body)
        client = request.get("clientId")
        assert request["lane"] == "live" and client in [row["clientId"] for row in connected]
        text = "bidi fixture" if client == bidi else "extension fixture"
        if refused.is_set():
            read_after_refusal.set()
            text = "READ AFTER THE REFUSAL"
        return 200, {"ok":True,"data":{"source":"live","clientId":client,
            "elapsed_ms":0,"tabs":[{"id":2,"title":"owned","url":url,"active":True}],
            "page":{"tabId":2,"title":"owned","url":url,"text":text,"chars":len(text),"truncated":False}}}

    def screenshot(body):
        request = json.loads(body)
        assert request["lane"] == "live" and request.get("clientId") == extension
        if clicked.is_set():
            captured_after_click.set()
        return 200, {"ok":True,"data":{"source":"live","clientId":extension,
            "tabId":2,"title":"owned","url":url,"mimeType":"image/png","data":png[0],"viewport":viewport,"elapsed_ms":0}}

    def act(body):
        actions.append(json.loads(body))
        clicked.set()
        return 200, {"ok":True,"data":{}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200,{"ok":True,"data":{"clients":connected}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/screenshot"] = RequestHttpResponse(screenshot)
    fixtures["/api/v1/dashboard/browser-lane/interact"] = RequestHttpResponse(act)

    chooser = b"Choose browser \xc2\xb7 separate sessions do not share login"
    extension_row = "Live Firefox · WebExtension: no hover, drag • b:choose browser".encode()
    extension_detail = "WebExtension: no hover, drag · BiDi serves them".encode()

    def interact(process, master, slave, output, _base):
        def image_drawn(start):
            wait_for_output(process, master, output, b"a=T", start=start, timeout=5)

        def settled_screen(needle, start):
            """The screen once the frame that drew [needle] after [start] is complete."""
            wait_for_output(process, master, output, needle, start=start, timeout=5)
            wait_for_output(process, master, output, FRAME_END,
                start=end_of_needle(output, needle, start), timeout=3)
            return screen_text(bytes(output[start:]))

        def require(screen, *needles):
            for needle in needles:
                if needle not in screen:
                    raise AssertionError(f"80-column screen lacks {needle!r}: {screen!r}")

        if bidi_listed:
            # Two connections are listed, so the lane asks which. The BiDi
            # connection's row has to fit too, with what it leaves out.
            palette_go(process, master, output, b"go Browser Lane", chooser)
            wait_for_output(process, master, output, "Firefox · BiDi · existing login".encode(),
                start=0, timeout=3)
            os.write(master, b"j")
            wait_for_terminal_input_consumed(slave)
            read_available(master, output)
            start = len(output)
            os.write(master, b"\r")
            require(settled_screen(b"bidi fixture", start),
                "Live Firefox · BiDi: no tab switch • b:choose browser".encode())
            read_available(master, output)
            start = len(output)
            os.write(master, b"b")
            require(settled_screen("Firefox · WebExtension · existing login".encode(), start),
                extension_detail)
            read_available(master, output)
            start = len(output)
            os.write(master, b"\r")
            require(settled_screen(b"extension fixture", start), extension_row)
        else:
            palette_go(process, master, output, b"go Browser Lane", b"extension fixture")
            require(screen_text(bytes(output)), extension_row)
        read_available(master, output)
        start = len(output)
        os.write(master, b"\x0f")
        image_drawn(start)
        # A point click is work this connection serves, so it is sent.
        os.write(master, b"\x1b[<0;2;5M\x1b[<0;2;5m")
        assert wait_for_fixture_event(process, master, output, clicked, timeout=5)
        assert wait_for_fixture_event(process, master, output, captured_after_click, timeout=5)
        read_available(master, output)
        image_drawn(len(output))
        assert len(actions) == 1 and actions[0]["action"] == "click_at", actions
        assert actions[0]["clientId"] == extension
        # A drag is not. Nothing is sent, the screenshot closes and the lane
        # says what was not sent and the next step.
        read_available(master, output)
        start = len(output)
        refused.set()
        os.write(master, b"\x1b[<0;2;5M\x1b[<0;5;8m")
        wait_for_output(process, master, output, b"Not sent", start=start, timeout=5)
        assert wait_for_fixture_event(process, master, output, read_after_refusal, timeout=5)
        after_refresh = settled_screen(b"READ AFTER THE REFUSAL", start)
        if bidi_listed:
            require(after_refresh,
                "Not sent · WebExtension: no drag · BiDi serves it · b:choose browser".encode())
        else:
            require(after_refresh,
                "Not sent · WebExtension: no drag · no BiDi connection is listed".encode(),
                b"Setup: docs/design/browser-bidi-live-host.md")
        if b"HTTP failed" in after_refresh:
            raise AssertionError(f"a gesture that was never sent reads as a failed read: {after_refresh!r}")
        assert len(actions) == 1, f"the unserved drag reached the lane: {actions!r}"
        # The next input withdraws the reason. j scrolls a page with nothing
        # to scroll, so the lane stays and the rows under the reason move up:
        # the connection row is drawn again only if the reason went.
        read_available(master, output)
        key_at = len(output)
        os.write(master, b"j")
        wait_for_output(process, master, output, b"Live Firefox", start=key_at, timeout=3)
        wait_for_output(process, master, output, FRAME_END,
            start=end_of_needle(output, b"Live Firefox", key_at), timeout=3)
        after_key = screen_text(bytes(output[start:]))
        require(after_key, extension_row, b"READ AFTER THE REFUSAL")
        if b"Not sent" in after_key or b"Setup:" in after_key:
            raise AssertionError(f"the next input left the refused gesture on screen: {after_key!r}")
        # The picker says the same thing about the connection under its cursor.
        read_available(master, output)
        start = len(output)
        os.write(master, b"b")
        require(settled_screen("Firefox · WebExtension · existing login".encode(), start),
            extension_detail)
        send_and_wait(process, master, output, b"\x1b", b"READ AFTER THE REFUSAL")
        send_and_wait(process, master, output, b"\x1b", b"MASC Dashboard")
        os.write(master, b"q")

    run_terminal_scenario(executable,
        description=("Browser screenshot gesture a listed connection serves instead" if bidi_listed
            else "Browser screenshot gesture the connection does not serve"),
        interact=interact, http_fixtures=fixtures, prepare_workspace=prepare, refresh=0.5,
        terminal_cols=80, preload_input=b"\x1b[6;20;10t"+GRAPHICS_SUPPORTED_REPLY)


def run_browser_viewport_cadence_regression(executable: str, *, follow_navigation: bool = False) -> None:
    fixtures = overview_event_http_fixtures()
    client = "11111111-1111-4111-8111-111111111111"
    url = "https://example.org/"
    viewport = {"documentId":"fixture","width":800,"height":600,"scrollX":0,"scrollY":0}
    observed_url = url + "next" if follow_navigation else url
    observed_viewport = dict(viewport, documentId="next-document") if follow_navigation else viewport
    captures, actions, png = [], [], [""]
    stale_started, stale_release = threading.Event(), threading.Event()
    closing_started, closing_release = threading.Event(), threading.Event()
    resumed_read = threading.Event()

    def prepare(base):
        seed_image_workspace(base)
        png[0] = base64.b64encode(Path(base, IMAGE_NAME).read_bytes()).decode()

    def read(body):
        request = json.loads(body)
        current_url = observed_url if len(captures) >= 2 else url
        text = "cadence fixture"
        if closing_release.is_set():
            # Ordinary cadence is blocked by refresh_pending until the delayed
            # screenshot completion is consumed by the UI mailbox.
            resumed_read.set()
            text = "CADENCE RESUMED AFTER DISMISSAL"
        return 200, {"ok":True,"data":{"source":request["lane"],"clientId":request.get("clientId"),
            "elapsed_ms":0,"tabs":[{"id":2,"title":"owned","url":current_url,"active":True}],
            "page":{"tabId":2,"title":"owned","url":current_url,"text":text,"chars":len(text),"truncated":False}}}

    def screenshot(body):
        request = json.loads(body)
        assert request == {"lane":"automation","tabId":2}
        captures.append(request)
        number = len(captures)
        title = {1:"INITIAL FRAME",2:"AUTOMATIC FRAME",3:"STALE FRAME",4:"DRAG FRAME"}.get(number,"CLOSED FRAME")
        if number == 3:
            stale_started.set()
            if not stale_release.wait(timeout=10):
                return 504, {"ok":False,"error":"stale fixture was not released"}
        elif number >= 5:
            closing_started.set()
            if not closing_release.wait(timeout=10):
                return 504, {"ok":False,"error":"closing fixture was not released"}
        return 200, {"ok":True,"data":{"source":"automation","clientId":None,"tabId":2,"title":title,"url":url if number == 1 else observed_url,
            "mimeType":"image/png","data":png[0],"viewport":viewport if number == 1 else observed_viewport,"elapsed_ms":0}}

    def act(body):
        request = json.loads(body)
        assert request == {"lane":"automation","tabId":2,"expectedUrl":observed_url,"action":"drag",
            "from":{"x":0.03,"y":0.06},"to":{"x":0.09,"y":0.18},"viewport":observed_viewport}
        actions.append(request)
        return 200, {"ok":True,"data":{}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200,{"ok":True,"data":{"clients":[{"clientId":client,"browser":"firefox","transport":"web_extension"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/screenshot"] = RequestHttpResponse(screenshot)
    fixtures["/api/v1/dashboard/browser-lane/interact"] = RequestHttpResponse(act)

    def interact(process, master, slave, output, _base):
        def image_after(start, title):
            wait_for_output(process, master, output, title, start=start, timeout=5)
            wait_for_output(process, master, output, b"j/k:center", start=end_of_needle(output,title,start), timeout=3)

        palette_go(process, master, output, b"go Browser Lane", b"cadence fixture")
        send_and_wait(process, master, output, b"a", b"cadence fixture")
        start = len(output)
        os.write(master,b"\x0f")
        image_after(start,b"INITIAL FRAME")
        # No refresh key: cadence follows a same-tab navigation by another actor
        # as well as an image change. The drag must use the displayed new URL
        # and document, while its pending predecessor cannot replace the frame.
        image_after(start,b"AUTOMATIC FRAME")
        assert wait_for_fixture_event(process,master,output,stale_started,timeout=5)
        start = len(output)
        os.write(master,b"\x1b[<0;2;5M\x1b[<0;5;8m")
        image_after(start,b"DRAG FRAME")
        assert len(actions)==1, "background observation blocked or replayed the gesture"
        # The old request settles after the effect-owned image. It must neither
        # replace that frame nor close the overlay, and must release single-flight.
        stale_release.set()
        assert wait_for_fixture_event(process,master,output,closing_started,timeout=5)
        assert b"STALE FRAME" not in output[start:]
        send_and_wait(process,master,output,b"\x1b",b"cadence fixture")
        start = len(output)
        closing_release.set()
        assert wait_for_fixture_event(process,master,output,resumed_read,timeout=5), \
            "ordinary cadence did not resume after consuming the delayed screenshot"
        wait_for_output(process,master,output,b"CADENCE RESUMED AFTER DISMISSAL",start=start,timeout=5)
        wait_for_output(process,master,output,FRAME_END,
            start=end_of_needle(output,b"CADENCE RESUMED AFTER DISMISSAL",start),timeout=3)
        # Stay on Browser Lane until the post-completion read is rendered:
        # leaving the surface would independently suppress a stale overlay.
        assert b"CLOSED FRAME" not in output[start:], "late cadence reopened the overlay"
        assert len(actions)==1 and len(captures)==5
        send_and_wait(process,master,output,b"\x1b",b"MASC Dashboard")
        os.write(master,b"q")

    try:
        run_terminal_scenario(executable,description=("Browser viewport follows same-tab navigation" if follow_navigation
                else "Open browser viewport cadence yields to drag and dismissal"),
            interact=interact,http_fixtures=fixtures,prepare_workspace=prepare,refresh=0.5,
            preload_input=b"\x1b[6;20;10t"+GRAPHICS_SUPPORTED_REPLY)
    finally:
        stale_release.set()
        closing_release.set()


def run_browser_screenshot_regression(executable: str) -> None:
    run_browser_viewport_cadence_regression(executable)
    run_browser_viewport_cadence_regression(executable, follow_navigation=True)
    run_browser_pointer_regression(executable)
    run_browser_unserved_gesture_regression(executable)
    run_browser_unserved_gesture_regression(executable, bidi_listed=True)
    run_browser_viewport_regression(executable)
    run_browser_viewport_regression(executable, cell_geometry=False)
    fixtures = overview_event_http_fixtures()
    client_id = "11111111-1111-4111-8111-111111111111"
    requests: list[dict[str, object]] = []
    png = [""]
    requested, release = threading.Event(), threading.Event()

    def prepare(base: str) -> None:
        seed_image_workspace(base)
        png[0] = base64.b64encode(Path(base, IMAGE_NAME).read_bytes()).decode()

    def read(body: bytes) -> HttpResponse:
        request = json.loads(body)
        tab_id = request.get("tabId", 2)
        title = "first" if tab_id == 1 else "second"
        return 200, {"ok": True, "data": {
            "source": request["lane"], "clientId": request.get("clientId"), "elapsed_ms": 12.5,
            "tabs": [{"id": n, "title": name, "url": "https://example.org/", "active": n == 2}
                     for n, name in [(1, "first"), (2, "second")]],
            "page": {"tabId": tab_id, "title": title, "url": "https://example.org/",
                     "text": title + " page body", "chars": 16, "truncated": False}}}

    def screenshot(body: bytes) -> HttpResponse:
        request = json.loads(body)
        requests.append(request)
        if len(requests) == 2:
            requested.set()
            if not release.wait(timeout=10):
                return 504, {"ok": False, "error": "fixture timeout"}
        if len(requests) == 4:
            return 404, {"ok": False, "error": "selected Firefox tab closed"}
        return 200, {"ok": True, "data": {
            "source": request["lane"], "clientId": request.get("clientId"), "tabId": request["tabId"], "title": "selected Firefox tab",
            "url": "https://example.org/", "mimeType": "image/png", "data": png[0], "viewport": {"documentId":"fixture","width":800,"height":600,"scrollX":0,"scrollY":0}, "elapsed_ms": 13.0}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True, "data": {"clients": [{"clientId": client_id, "browser": "firefox", "transport": "web_extension"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/screenshot"] = RequestHttpResponse(screenshot)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        if hasattr(termios, "VDISCARD"):
            cc = termios.tcgetattr(_slave_fd)[6][termios.VDISCARD]
            discard = cc if isinstance(cc, int) else cc[0]
            if discard != os.fpathconf(_slave_fd, "PC_VDISABLE"):
                raise AssertionError("raw mode did not reclaim Ctrl-O from VDISCARD")
        palette_go(process, master_fd, output, b"go Browser Lane", b"second page body")

        def capture() -> None:
            read_available(master_fd, output)
            start = len(output)
            os.write(master_fd, b"\x0f")
            wait_for_output(process, master_fd, output, b"a=T", start=start, timeout=3.0)
            if b"f=100" not in bytes(output[start:]):
                raise AssertionError("screenshot did not use the PNG image viewer")

        capture()
        if requests != [{"lane": "live", "clientId": client_id, "tabId": 2}]:
            raise AssertionError(f"screenshot did not bind the selected live tab: {requests!r}")
        send_and_wait(process, master_fd, output, b"\x1b", b"second page body")
        send_and_wait(process, master_fd, output, b"a", b"second page body")
        send_and_wait(process, master_fd, output, b"g", b"Ctrl-U:clear")
        draft = b"https://example.org/?q=draft"
        send_and_wait(process, master_fd, output, b"\x1b[200~" + draft + b"\x1b[201~", draft)
        os.write(master_fd, b"\x0f")
        if not wait_for_fixture_event(process, master_fd, output, requested, timeout=3.0):
            raise AssertionError("screenshot request never reached the fixture")
        send_and_wait(process, master_fd, output, b"x", draft + b"x")
        # Enter intentionally does not change this busy frame. Observe its
        # state after a real resize, rather than requiring unchanged rows to
        # be emitted again by the differential frame presenter.
        os.write(master_fd, b"\r")
        wait_for_terminal_input_consumed(_slave_fd)
        drain_until_quiet(process, master_fd, output)
        retained = resize_and_wait(process, master_fd, output,
            rows=31, columns=101, needle=b"Enter after completion", controls=(FULL_REDRAW,))
        if draft + b"x" not in CSI_RE.sub(b"", retained):
            raise AssertionError("pending screenshot lost the URL or its deferred Enter explanation")
        read_available(master_fd, output)
        cancelled_from = len(output)
        release.set()
        wait_for_output(process, master_fd, output, b"Read 12.5 ms", start=cancelled_from, timeout=3.0)
        if b"a=T" in bytes(output[cancelled_from:]):
            raise AssertionError("cancelled screenshot interrupted the URL draft")
        # A cancelled preview still settles its operation, so another capture works.
        capture()
        restored = send_and_wait(process, master_fd, output, b"\x1b", draft + b"x")
        if draft + b"x " in CSI_RE.sub(b"", restored).split(b"\xe2\x96\x8f")[0]:
            raise AssertionError("image dismissal typed into the retained URL draft")
        send_and_wait(process, master_fd, output, b"\x1b", b"g:URL")
        send_and_wait(process, master_fd, output, b"]", b"first page body")
        send_and_wait(process, master_fd, output, b"\x0f", b"selected Firefox tab closed")
        if requests[-1] != {"lane": "automation", "tabId": 1}:
            raise AssertionError("closed-tab screenshot silently changed target")
        send_and_wait(process, master_fd, output, b"r", b"second page body")
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
        os.write(master_fd, b"q")

    try:
        run_terminal_scenario(executable, description="Browser screenshot ownership and URL preservation",
            interact=interact, http_fixtures=fixtures, prepare_workspace=prepare,
            preload_input=GRAPHICS_SUPPORTED_REPLY)
    finally:
        release.set()
