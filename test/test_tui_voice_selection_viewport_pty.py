"""Voice typing and both assignment cursors remain visible after resize."""
import json
import os
import sys
from pathlib import Path

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_voice as _keyboard_voice

SOURCE_MODULES = ("test/tui_keyboard_harness.py", "test/tui_keyboard_voice.py", "bin/masc_tui_render.ml", "bin/masc_tui.ml")
CARET = "▏".encode()


def settle(process, fd, output, keys):
    _keyboard_harness.press_and_settle(process, fd, output, keys, cap=15.0)
    return _keyboard_harness.screen_rows(bytes(output))


def selected(rows, needle):
    # The fixture ids encode the expected cursor. The fixed selector header
    # names the role, its position and its value above the scrolling body.
    label, _, suffix = needle.rpartition(b"-")
    prefix = b"  " + label + b" " + str(int(suffix) + 1).encode() + b"/32: "
    # Voice headers show the endpoint's display name; Enter sends its id.
    value = b"Voice " + suffix if label == b"voice" else needle
    matches = [row for row in rows.values()
               if prefix + value in row]
    if len(matches) != 1:
        raise AssertionError(f"expected visible selection {needle!r}: {rows!r}")


def wizard(executable):
    requests = []

    def interact(process, fd, _slave, output, _base):
        _keyboard_voice.open_the_voice_pane(process, fd, output)
        settle(process, fd, output, b"e")
        settle(process, fd, output, b"\r\r")
        # Name is a free text field; neither length nor wide terminal cells
        # may hide its insertion point. Test both narrow and wide geometry.
        for text in ("prefix-" + "abcdef" * 24 + "-ASCII-END",
                     "머리-" + "가나다라마바사" * 24 + "-한글끝"):
            # The initial Name field is empty: clearing it alone need not
            # produce a changed frame. Typing after clear gives settle a
            # meaningful redraw while still replacing the previous value.
            rows = settle(process, fd, output, b"\x15" + text.encode())
            suffix = text[-8:].encode()
            for height, width in ((24, 64), (40, 110), (24, 80)):
                _keyboard_harness.resize_and_wait(process, fd, output, rows=height,
                                  columns=width, needle=CARET,
                                  controls=(_keyboard_harness.FULL_REDRAW,))
                rows = _keyboard_harness.screen_rows(bytes(output))
                fields = [row for row in rows.values() if CARET in row]
                if len(fields) != 1 or suffix + CARET not in fields[0]:
                    raise AssertionError(f"typed tail/caret missing at {width}: {rows!r}")
            # Backspace removes a whole UTF-8 scalar, not its last byte.
            settle(process, fd, output, b"\x7f")
            rows = _keyboard_harness.screen_rows(bytes(output))
            if not any(text[-8:-1].encode() + CARET in row for row in rows.values()):
                raise AssertionError(f"backspace did not keep the caret at the tail: {rows!r}")
        settle(process, fd, output, b"\x1b")
        if any(path == "/api/v1/voice/setup" and body for path, body in requests):
            raise AssertionError("cancelled typing changed a voice configuration")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Voice long text keeps its tail and caret",
                           interact=interact, http_fixtures=_keyboard_voice.voice_wizard_http_fixtures(),
                           http_requests=requests)


def assignment(executable):
    requests = []
    fixtures = _keyboard_voice.voice_wizard_http_fixtures()
    agents = [f"keeper-{index:02d}" for index in range(32)]
    roster = _keyboard_harness.keeper_runtime_http_fixtures()["/api/v1/gate/keepers?detailed=true"][1]
    prototype = roster["keepers"][0]
    fixtures["/api/v1/gate/keepers?detailed=true"] = (200, {
        "count": len(agents), "total": len(agents), "truncated": False,
        "keepers": [{**prototype, "name": agent, "meta": _keyboard_harness.keeper_roster_meta(agent)}
                    for agent in agents],
    })
    fixtures["/api/v1/voice/voices"] = (200, {
        "voices": [{"id": f"voice-{index:02d}", "name": f"Voice {index:02d}"}
                   for index in range(32)],
    })

    def prepare_workspace(base_path):
        # Voice assignments read the local Keeper metadata. Replace only
        # the two default names seeded in this scenario's temporary workspace.
        keepers = Path(base_path) / ".masc" / "keepers"
        for name in ("alpha", "beta"):
            (keepers / f"{name}.json").unlink()
        for agent in agents:
            (keepers / f"{agent}.json").write_text(
                json.dumps(_keyboard_harness.keeper_metadata(agent)), encoding="utf-8")

    def interact(process, fd, _slave, output, _base):
        _keyboard_voice.open_the_voice_pane(process, fd, output)
        # Roster data is independently loaded by refresh, so wait for its
        # ready signal in the roster before opening the assignment screen.
        roster_start = len(output)
        _keyboard_harness.tab_until(process, fd, output, b"MASC Keepers")
        _keyboard_harness.wait_for_output(process, fd, output, b"keeper-00",
                          start=roster_start, timeout=15)
        # The selected Config pane survives the roster visit.
        _keyboard_harness.tab_until(process, fd, output, b"MASC Voice")
        settle(process, fd, output, b"a")
        _keyboard_harness.wait_for_output(process, fd, output, b"voice-00", start=0, timeout=15)
        _keyboard_harness.drain_until_quiet(process, fd, output)
        rows = _keyboard_harness.screen_rows(bytes(output))
        selected(rows, b"keeper-00")
        selected(rows, b"voice-00")
        # Each list overflows even a tall frame. Walking one must leave the
        # other selection visible and Enter must send exactly this pair.
        for index in range(1, 32):
            rows = settle(process, fd, output, b"j\x1b[C")
            selected(rows, f"keeper-{index:02d}".encode())
            selected(rows, f"voice-{index:02d}".encode())
        for height, width in ((24, 64), (40, 110), (24, 80)):
            _keyboard_harness.resize_and_wait(process, fd, output, rows=height, columns=width,
                              needle=b"voice-31", controls=(_keyboard_harness.FULL_REDRAW,))
            rows = _keyboard_harness.screen_rows(bytes(output))
            selected(rows, b"keeper-31")
            selected(rows, b"voice-31")
            if not any(b"Enter:assign" in row for row in rows.values()):
                raise AssertionError(f"assignment footer hidden: {rows!r}")
        requests.clear()
        _keyboard_harness.resize_and_wait(process, fd, output, rows=10, columns=80,
                          needle=b"terminal too small", controls=(_keyboard_harness.FULL_REDRAW,))
        _keyboard_harness.write_all(fd, output, b"j\x1b[C\r")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        if any(path == "/api/v1/voice/setup" and body for path, body in requests):
            raise AssertionError("hidden assignment accepted Enter in a compact frame")
        _keyboard_harness.resize_and_wait(process, fd, output, rows=24, columns=80,
                          needle=b"voice-31", controls=(_keyboard_harness.FULL_REDRAW,))
        rows = _keyboard_harness.screen_rows(bytes(output))
        selected(rows, b"keeper-31")
        selected(rows, b"voice-31")
        os.write(fd, b"\r")
        body = json.loads(_keyboard_harness.wait_for_http_request(process, fd, output, requests,
                                                 path="/api/v1/voice/setup"))
        if body.get("changes") != [{"change": "set_agent_voice",
                                    "agent": "keeper-31", "voice": "voice-31"}]:
            raise AssertionError(f"Enter saved a different pair: {body!r}")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        rows = settle(process, fd, output, b"j\x1b[C")
        selected(rows, b"keeper-00")
        selected(rows, b"voice-00")
        rows = settle(process, fd, output, b"k\x1b[D")
        selected(rows, b"keeper-31")
        selected(rows, b"voice-31")
        settle(process, fd, output, b"\x1b")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Voice assignment follows both selections",
                           interact=interact, http_fixtures=fixtures,
                           http_requests=requests, prepare_workspace=prepare_workspace)


if __name__ == "__main__":
    binary = os.path.abspath(sys.argv[1])
    wizard(binary)
    assignment(binary)
    print("Voice text and assignment viewports: PASS")
