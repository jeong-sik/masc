"""A 200-node browser scene stays scrollable under a keystroke burst.

Object analysis puts up to 200 nodes into the lane. Every scroll key asked
for the row count and every frame asked for the rows, and building either one
walked the node list once per node -- so the burst below used to cost two full
projections per keypress. The deadline is what separates that from reading a
retained array.
"""
import os
import sys
import time
import test_tui_keyboard_input as h

CLIENT = "11111111-1111-4111-8111-111111111111"
URL = "https://example.org/scene"
NODE_COUNT = 200
# browser_scene_script.ml's nodeLimit. Each text is short enough to wrap to one
# row at the scenario's width, so a row's number is its node's number.
FIRST_ROW = b"[>1] BROWSER SCENE ROW 000"
LAST_ROW = b"BROWSER SCENE ROW 199"


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()

    def node(index: int) -> dict:
        return {"nodeId": f"node-{index:03d}", "kind": "text", "tag": "p",
                "text": f"BROWSER SCENE ROW {index:03d}",
                "rects": [{"x": 0, "y": index * 20, "width": 100, "height": 20}],
                "color": "rgb(0,0,0)", "fontSize": 16, "fontWeight": "400",
                "whiteSpace": "normal"}

    def read(_body):
        return 200, {"ok": True, "data": {"source": "live", "clientId": CLIENT,
            "elapsed_ms": 12.5,
            "tabs": [{"id": 2, "title": "scene", "url": URL, "active": True}],
            "page": {"tabId": 2, "title": "scene", "url": URL,
                     "text": "scene reader ready", "chars": 18, "truncated": False}}}

    def scene(_body):
        return 200, {"ok": True, "data": {"source": "live", "clientId": CLIENT,
            "tabId": 2, "elapsed_ms": 13.0, "schema": "masc.browser.scene.v1",
            "view": "content", "scope": None, "documentId": "document-scroll",
            "url": URL, "title": "scene", "truncated": False,
            "viewport": {"width": 800, "height": 600, "scrollX": 0, "scrollY": 0},
            "nodes": [node(index) for index in range(NODE_COUNT)]}}

    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True,
        "data": {"clients": [{"clientId": CLIENT, "browser": "zen"}]}})
    fixtures["/api/v1/dashboard/browser-lane/read"] = h.RequestHttpResponse(read)
    fixtures["/api/v1/dashboard/browser-lane/scene"] = h.RequestHttpResponse(scene)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go Browser Lane", b"scene reader ready")
        h.send_and_wait(process, fd, output, b"s", FIRST_ROW)
        h.read_available(fd, output)
        start = len(output)
        # More presses than there are rows, so the lane saturates at the bottom
        # whatever the terminal height. One projection per press is what the
        # deadline rejects.
        deadline = time.monotonic() + 5.0
        h.write_all(fd, output, b"j" * 300)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError("scroll burst delivery exceeded the deadline")
        h.wait_for_output(process, fd, output, LAST_ROW, start=start, timeout=remaining)
        h.wait_for_output(process, fd, output, h.FRAME_END,
                          start=h.end_of_needle(output, LAST_ROW, start), timeout=3)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="200-node browser scene scroll burst",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Browser lane scene scrolling: PASS")
