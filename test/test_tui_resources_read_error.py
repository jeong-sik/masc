"""A failed MCP resource read shows its operation and cause once."""

import json
import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_async_read.ml",
    "bin/masc_tui_http.ml",
    "bin/masc_tui_mcp.ml",
    "bin/masc_tui_render.ml",
)

ERRORS = (
    (
        "rpc",
        b"resource read: MCP error:",
        b'resource read: MCP error: {"code":-32000,"message":"fixture read denied"}',
    ),
    (
        "http",
        b"resource read: HTTP 503:",
        b"resource read: HTTP 503: fixture service unavailable",
    ),
)


def run_case(executable: str, kind: str, prefix: bytes, expected: bytes) -> None:
    fixtures = h.resources_mcp_fixture()
    # The observer GET has no JSON-RPC body. Keep it out of the POST callback;
    # this fixture exercises resource reads and has no observer events to send.
    fixtures["/mcp?sse_kind=observer"] = h.RawHttpResponse(
        200, b"", content_type="text/event-stream"
    )
    original = fixtures["/mcp"]
    assert isinstance(original, h.RequestHttpResponse)

    def answer(body: bytes):
        request = json.loads(body)
        if request.get("method") != "resources/read":
            return original.resolve(body)
        if kind == "http":
            return h.RawHttpResponse(
                503,
                b'{"error":"fixture service unavailable"}',
                content_type="application/json",
            )
        payload = {
            "jsonrpc": "2.0",
            "id": request["id"],
            "error": {"code": -32000, "message": "fixture read denied"},
        }
        return h.RawHttpResponse(
            200, json.dumps(payload).encode(), content_type="application/json"
        )

    fixtures["/mcp"] = h.RequestHttpResponse(answer)

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Config")
        h.send_and_wait(process, fd, output, b"s", b"Event Log (JSON)")
        h.send_and_wait(process, fd, output, b"\r", prefix)
        h.resize_and_wait(
            process, fd, output, rows=30, columns=200,
            needle=prefix, controls=(h.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        screen = h.screen_text(bytes(output))
        if screen.count(prefix) != 1 or screen.count(expected) != 1:
            raise AssertionError(f"Resource failure lost its cause: {screen!r}")
        if b"Read failed:" in screen or b"resources/read error:" in screen:
            raise AssertionError(f"Resource failure was repeated: {screen!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description=f"MCP resource {kind} read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


def run(executable: str) -> None:
    for kind, prefix, expected in ERRORS:
        run_case(executable, kind, prefix, expected)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("MCP resource read failure once: PASS")
