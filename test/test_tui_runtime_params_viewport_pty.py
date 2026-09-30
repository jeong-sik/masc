"""Full parameter values/contracts remain reachable without moving selection."""
import json
import os
import re
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render.ml", "bin/masc_tui_types.ml",
    "bin/masc_tui_render_prim.ml", "bin/masc_tui.ml", "bin/masc_tui_keys.ml",
)
TEXT_KEY = "00." + "segment." * 10 + "KEYEND"
BOOL_KEY = "01.enabled"
ZERO_KEY = "02.count"
CONTRACT_ROWS = [f"contract-row-{index:02d}" for index in range(36)]


def detail_position(screen):
    match = re.search(rb"\b(\d+)-(\d+)/(\d+)\b", screen)
    if match is None:
        raise AssertionError(f"detail position missing: {screen!r}")
    return tuple(map(int, match.groups()))


def run(executable):
    requests = []
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/runtime/params"] = (200, {
        "parameters": [
            {"key": TEXT_KEY, "current": "현재값 " * 30 + " CURRENT-END",
             "default": "default segment " * 30 + " DEFAULT-END", "has_override": True,
             "meta": {"value_type": "string", "description": "긴 설정 계약 " * 30
                      + "\n" + "\n".join(CONTRACT_ROWS) + "\nCONTRACT-END"}},
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
        tokens.update(row.encode() for row in CONTRACT_ROWS)
        seen = set()
        previous = None
        prior_window = None
        for _ in range(90):
            screen = h.screen_text(bytes(output))
            window = re.search(rb"\b(\d+)-(\d+)/(\d+)\b", screen)
            if window is None:
                raise AssertionError(f"detail window position missing: {screen!r}")
            first, last, total = map(int, window.groups())
            if prior_window is not None and first != prior_window[0]:
                # A non-final page starts on the previous page's last row.
                # At the final clamp the overlap can grow, but cannot vanish.
                if first > prior_window[1]:
                    raise AssertionError(f"page skipped rows: {prior_window!r} -> {(first, last, total)!r}")
                if last < total and first != prior_window[1]:
                    raise AssertionError(f"page lacks exact one-row overlap: {prior_window!r} -> {(first, last, total)!r}")
            prior_window = first, last, total
            # Exact JSON values split at terminal cells, including inside a
            # marker. Join painted row padding before checking reachability;
            # the one-row page overlap above keeps adjacent chunks together.
            painted_text = b"".join(screen.split())
            seen.update(token for token in tokens if token in painted_text)
            if seen == tokens:
                h.write_all(fd, output, b"\x1b[5~")
                h.drain_until_quiet(process, fd, output)
                back = re.search(rb"\b(\d+)-(\d+)/(\d+)\b", h.screen_text(bytes(output)))
                expected = max(1, first - (last - first))
                if back is None or int(back.group(1)) != expected:
                    raise AssertionError(f"PageUp did not use the actual detail height: {expected}, {back!r}")
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
                              needle=b"j/k selects", controls=(h.FULL_REDRAW,))
            scan(process, fd, output)
        # Scrolling the selected contract must not change the key Enter edits.
        settle(process, fd, output, b"\x1b[H")
        settle(process, fd, output, b"\r")
        settle(process, fd, output, b"\x15typed value")
        before = detail_position(h.screen_text(bytes(output)))
        requests.clear()
        after_screen = settle(process, fd, output, b"\x1b[6~")
        after = detail_position(after_screen)
        if after[0] != before[1]:
            raise AssertionError(f"editor PageDown did not use detail height: {before!r} -> {after!r}")
        if b"typed value" not in after_screen or b"editing " not in after_screen:
            raise AssertionError(f"editor paging changed draft or key: {after_screen!r}")
        back = detail_position(settle(process, fd, output, b"\x1b[5~"))
        if back != before:
            raise AssertionError(f"editor PageUp did not restore detail position: {before!r} -> {back!r}")
        if any(path == "/api/v1/runtime/params/set" for path, _ in requests):
            raise AssertionError("editor paging wrote a value")
        submit(process, fd, output, TEXT_KEY, "typed value")
        settle(process, fd, output, b"j")
        screen = settle(process, fd, output, b"\r")
        if b"choice>" not in screen or b"off" not in screen:
            raise AssertionError(f"false was lost on opening the bool editor: {screen!r}")
        submit(process, fd, output, BOOL_KEY, False)
        settle(process, fd, output, b"j")
        settle(process, fd, output, b"\r")
        # Invalid int draft is refused locally and stays in the editor.
        screen = settle(process, fd, output, b"\x15invalid")
        before = detail_position(screen)
        after_screen = settle(process, fd, output, b"\x1b[6~")
        # Even a short contract keeps the draft and edit target intact.
        if b"invalid" not in after_screen or ("editing " + ZERO_KEY).encode() not in after_screen:
            raise AssertionError(f"paging changed the invalid draft or key: {after_screen!r}")
        settle(process, fd, output, b"\x1b[5~")
        if detail_position(h.screen_text(bytes(output))) != before:
            raise AssertionError("invalid-draft paging changed the initial viewport")
        screen = settle(process, fd, output, b"\r")
        if any(path == "/api/v1/runtime/params/set" and json.loads(body).get("param_key") == ZERO_KEY
               for path, body in requests):
            raise AssertionError("invalid integer reached the write route")
        settle(process, fd, output, b"\x150")
        submit(process, fd, output, ZERO_KEY, 0)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Runtime params preserve full values and selection",
                           interact=interact, http_fixtures=fixtures, http_requests=requests)


def refresh_identity(executable):
    requests = []
    served = h.keeper_runtime_http_fixtures()
    keys = ["param-a", "param-b", "param-c", "param-inserted"]
    entries = {key: {"key": key, "current": index, "default": 0,
                     "has_override": True, "meta": {"value_type": "int", "description": key}}
               for index, key in enumerate(keys)}
    orders = [keys[:3], [keys[2], keys[3], keys[0], keys[1]],
              [keys[1], keys[0], keys[2], keys[3]]]
    reads = [0]

    def answer():
        order = orders[min(reads[0], len(orders) - 1)]
        reads[0] += 1
        return 200, {"parameters": [entries[key] for key in order]}

    served["/api/v1/runtime/params"] = answer
    served["/api/v1/runtime/params/set"] = (200, {"ok": True})

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go system", b"MASC System")
        h.press_and_settle(process, fd, output, b"p")
        h.press_and_settle(process, fd, output, b"p")
        h.wait_for_output(process, fd, output, b"param-a", start=0, timeout=15)
        h.drain_until_quiet(process, fd, output)
        for _ in range(2):
            h.press_and_settle(process, fd, output, b"r")
            h.drain_until_quiet(process, fd, output)
            h.press_and_settle(process, fd, output, b"\r")
            rows = h.screen_rows(bytes(output))
            if not any(b"editing param-a" in row for row in rows.values()):
                raise AssertionError(f"refresh changed the edit target: {rows!r}")
            h.press_and_settle(process, fd, output, b"\x1b")
        requests.clear()
        h.press_and_settle(process, fd, output, b"\r")
        os.write(fd, b"\r")
        body = json.loads(h.wait_for_http_request(process, fd, output, requests,
                                                 path="/api/v1/runtime/params/set"))
        if body != {"param_key": "param-a", "value": 0}:
            raise AssertionError(f"Enter after reorder applied to a different key: {body!r}")
        h.drain_until_quiet(process, fd, output)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Runtime params preserve key identity after refresh",
                           interact=interact, http_fixtures=served, http_requests=requests)


def boundary_and_string_values(executable):
    fixtures = h.keeper_runtime_http_fixtures()
    # At 40 columns the value document has 32 cells: the JSON opening
    # quote plus a 31-cell prefix fills a row exactly. The next row must
    # retain one versus two spaces, including after a CJK prefix.
    prefixes = ["a" * 31, "한" * 15 + "x"]
    values = ["\nfoo\n", "  foo", "", "foo"]
    values += [prefix + spaces + "END" for prefix in prefixes for spaces in (" ", "  ")]
    keys = [f"value-{index}" for index in range(len(values))]
    choices = ["a b", "a  b", " leading · trailing "]
    fixtures["/api/v1/runtime/params"] = (200, {
        "parameters": [
            {"key": key, "current": value, "default": value,
             "has_override": False,
             "meta": {"value_type": "string", "description": "\n".join(CONTRACT_ROWS),
                      "choices": choices if key == keys[0] else []}}
            for key, value in zip(keys, values)
        ],
    })

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go system", b"MASC System")
        h.press_and_settle(process, fd, output, b"p")
        h.press_and_settle(process, fd, output, b"p")
        h.wait_for_output(process, fd, output, b"value-0", start=0, timeout=15)
        h.drain_until_quiet(process, fd, output)

        def press(keys):
            # Boundary inputs and Home can be no-ops, so a frame is optional.
            h.write_all(fd, output, keys)
            if not h.drain_until_quiet(process, fd, output):
                raise AssertionError("parameter frame did not settle")
            return h.screen_text(bytes(output))

        def position(screen):
            match = re.search(rb"\b(\d+)-(\d+)/(\d+)\b", screen)
            if match is None:
                raise AssertionError(f"detail position missing: {screen!r}")
            return tuple(map(int, match.groups()))

        h.resize_and_wait(process, fd, output, rows=32, columns=40,
                          needle=b"j/k selects", controls=(h.FULL_REDRAW,))
        for index, value in enumerate(values):
            screen = press(b"\x1b[H")
            literal = json.dumps(value, ensure_ascii=False).encode()
            if index < 4:
                if screen.count(literal) < 2:
                    raise AssertionError(f"current/default value lost its JSON representation: {literal!r}; {screen!r}")
            else:
                spaces = b" " if (index - 4) % 2 == 0 else b"  "
                expected = b"      " + spaces + b'END"'
                rows = h.screen_rows(bytes(output))
                matching = [row for row in rows.values() if row.startswith(expected)]
                if len(matching) != 2:
                    raise AssertionError(f"wrapped current/default lost boundary spaces: {expected!r}; {rows!r}")
                prefix = prefixes[(index - 4) // 2].encode()
                if screen.count(b'"' + prefix) < 2:
                    raise AssertionError(f"wrapped value lost its ASCII/CJK prefix: {screen!r}")
            if index == 0:
                expected_choices = {json.dumps(choice, ensure_ascii=False).encode() for choice in choices}
                seen_choices = set()
                for _ in range(40):
                    seen_choices.update(choice for choice in expected_choices if choice in screen)
                    start, end, total = position(screen)
                    if end >= total:
                        break
                    screen = press(b"\x1b[6~")
                if seen_choices != expected_choices:
                    raise AssertionError(f"choice spellings lost spaces or punctuation: {expected_choices - seen_choices!r}")
                press(b"\x1b[H")
            if index in (0, len(values) - 1):
                before = position(press(b"\x1b[6~"))
                if before[0] <= 1:
                    raise AssertionError(f"fixture did not scroll the contract: {before!r}")
                after = position(press(b"k" if index == 0 else b"j"))
                if after != before:
                    raise AssertionError(f"boundary selection lost detail offset: {before!r} -> {after!r}")
            if index < len(values) - 1:
                screen = press(b"j")
                if position(screen)[0] != 1:
                    raise AssertionError(f"different selection retained detail offset: {screen!r}")
        screen = press(b"k")
        if position(screen)[0] != 1:
            raise AssertionError(f"previous selection retained detail offset: {screen!r}")
        # Enter still edits the selected key after the boundary input.
        screen = press(b"\r")
        if f"editing value-{len(values) - 2}".encode() not in screen:
            raise AssertionError(f"selection identity changed: {screen!r}")
        press(b"\x1b")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Runtime params preserve boundary reading and exact strings",
                           interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    refresh_identity(os.path.abspath(sys.argv[1]))
    boundary_and_string_values(os.path.abspath(sys.argv[1]))
    print("Runtime parameter value/contract viewport: PASS")
