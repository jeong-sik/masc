"""Full parameter values/contracts remain reachable without moving selection."""
import json
import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render.ml", "bin/masc_tui_types.ml",
    "bin/masc_tui_render_prim.ml", "bin/masc_tui.ml", "bin/masc_tui_keys.ml",
)
TEXT_KEY = "00." + "segment." * 10 + "KEYEND"
BOOL_KEY = "01.enabled"
ZERO_KEY = "02.count"


def run(executable):
    requests = []
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/runtime/params"] = (200, {
        "parameters": [
            {"key": TEXT_KEY, "current": "현재값 " * 30 + " CURRENT-END",
             "default": "default segment " * 30 + " DEFAULT-END", "has_override": True,
             "meta": {"value_type": "string", "description": "긴 설정 계약 " * 30 + " CONTRACT-END"}},
            {"key": BOOL_KEY, "current": False, "default": True, "has_override": True,
             "meta": {"value_type": "bool", "description": "Boolean value remains false"}},
            {"key": ZERO_KEY, "current": 0, "default": 7, "has_override": True,
             "meta": {"value_type": "int", "description": "Zero is a valid count", "min_value": 0}},
        ],
        "surfaces": [{"id": "fixture", "description": "한글 그룹 설명 " * 20 + " GROUP-END",
                      "param_keys": [TEXT_KEY, BOOL_KEY, ZERO_KEY]}],
    })
    fixtures["/api/v1/runtime/params/set"] = (200, {"ok": True})

    def settle(process, fd, output, keys):
        h.press_and_settle(process, fd, output, keys, cap=15)
        return h.screen_text(bytes(output))

    def scan(process, fd, output):
        # Home may already be at row zero; do not require a redraw for a no-op.
        h.write_all(fd, output, b"\x1b[H")
        h.drain_until_quiet(process, fd, output)
        tokens = {b"KEYEND", b"CURRENT-END", b"DEFAULT-END", b"CONTRACT-END", b"GROUP-END"}
        seen = set()
        previous = None
        for _ in range(90):
            screen = h.screen_text(bytes(output))
            seen.update(token for token in tokens if token in screen)
            if seen == tokens:
                return
            if screen == previous:
                break
            previous = screen
            h.write_all(fd, output, b"\x1b[6~")
            h.drain_until_quiet(process, fd, output)
        raise AssertionError(f"full param content unreachable: {tokens - seen!r}; {screen!r}")

    def submit(process, fd, output, key, value):
        requests.clear()
        os.write(fd, b"\r")
        body = json.loads(h.wait_for_http_request(process, fd, output, requests,
                                                 path="/api/v1/runtime/params/set"))
        if body != {"param_key": key, "value": value}:
            raise AssertionError(f"selection/value changed on apply: {body!r}")
        h.drain_until_quiet(process, fd, output)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go system", b"MASC System")
        settle(process, fd, output, b"p")
        settle(process, fd, output, b"p")
        h.wait_for_output(process, fd, output, b"KEYEND", start=0, timeout=15)
        h.drain_until_quiet(process, fd, output)
        for rows, columns in ((24, 40), (20, 60), (28, 80)):
            h.resize_and_wait(process, fd, output, rows=rows, columns=columns,
                              needle=b"MASC System", controls=(h.FULL_REDRAW,))
            scan(process, fd, output)
        # Scrolling the selected contract must not change the key Enter edits.
        settle(process, fd, output, b"\r")
        settle(process, fd, output, b"\x15typed value")
        submit(process, fd, output, TEXT_KEY, "typed value")
        settle(process, fd, output, b"j")
        screen = settle(process, fd, output, b"\r")
        if b"choice>" not in screen or b"off" not in screen:
            raise AssertionError(f"false was lost on opening the bool editor: {screen!r}")
        submit(process, fd, output, BOOL_KEY, False)
        settle(process, fd, output, b"j")
        settle(process, fd, output, b"\r")
        # Invalid int draft is refused locally and stays in the editor.
        screen = settle(process, fd, output, b"\x15invalid\r")
        if any(path == "/api/v1/runtime/params/set" and json.loads(body).get("param_key") == ZERO_KEY
               for path, body in requests):
            raise AssertionError("invalid integer reached the write route")
        settle(process, fd, output, b"\x150")
        submit(process, fd, output, ZERO_KEY, 0)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Runtime params preserve full values and selection",
                           interact=interact, http_fixtures=fixtures, http_requests=requests)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Runtime parameter value/contract viewport: PASS")
