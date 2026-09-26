"""A failed MCP resource read shows its operation and cause once."""

import json
import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml",)

ERROR_PREFIX = b"resources/read error:"
ERROR_CAUSE = b"fixture read denied"


def run(executable: str) -> None:
    fixtures = h.resources_mcp_fixture()
    original = fixtures["/mcp"]
    assert isinstance(original, h.RequestHttpResponse)

    def answer(body: bytes):
        request = json.loads(body)
        if request.get("method") != "resources/read":
            return original.resolve(body)
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
        h.send_and_wait(process, fd, output, b"\r", ERROR_PREFIX)
        h.resize_and_wait(
            process, fd, output, rows=30, columns=200,
            needle=ERROR_PREFIX, controls=(h.FULL_REDRAW,),
        )
        screen = h.screen_text(bytes(output))
        if screen.count(ERROR_PREFIX) != 1 or screen.count(ERROR_CAUSE) != 1:
            raise AssertionError(f"Resource failure lost its cause: {screen!r}")
        if b"Read failed:" in screen:
            raise AssertionError(f"Resource failure was repeated: {screen!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="MCP resource read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("MCP resource read failure once: PASS")
