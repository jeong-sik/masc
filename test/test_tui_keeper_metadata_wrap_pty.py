"""Keeper Info and Channels expose long metadata through their row window."""
import json
import os
from pathlib import Path
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml", "bin/masc_tui_message_layout.ml",
                  "bin/masc_tui_message_layout.mli")
TASK = "task-" + "segment-" * 11 + "END"
STATUS_PATH = "/runtime/" + "deep-directory/" * 14 + " STATUS-PATH-END"
STORE_PATH = "/runtime/" + "한글경로/" * 18 + " STORE-PATH-END"
ENDPOINT = "https://fixture.invalid/" + "segment/" * 20 + " ENDPOINT-END"
ERROR = "directory failed " + "한글 오류 원인을 모두 보여야 합니다 " * 16 + " ERROR-END"


def prepare(base):
    path = Path(base) / ".masc" / "keepers" / "alpha.json"
    meta = json.loads(path.read_text())
    meta["current_task_id"] = TASK
    path.write_text(json.dumps(meta), encoding="utf-8")


def fixtures():
    served = h.keeper_runtime_http_fixtures()
    served["/api/v1/dashboard/gate/keeper-settings"] = (503, {
        "error": "설정 읽기 실패 " * 20 + " GATE-END 한글끝",
    })
    served[h.CONNECTORS_PATH] = (200, {
        "connectors": [{
            "connector_id": "discord", "display_name": "Discord", "status": "connected",
            "available": True, "connected": True,
            "status_path": STATUS_PATH, "binding_store_path": STORE_PATH,
            "gate_base_url": ENDPOINT, "directory_errors": [ERROR],
            "configured_bindings": [{"channel_id": "111", "keeper_name": "alpha"}],
        }], "total": 1, "active_count": 1,
    })
    served[h.CONNECTOR_NAMES_PATH] = (200, {
        "connector_id": "discord", "kind": "channel", "mapping_scope": "workspace",
        "path": "connector_names/discord/channel", "total": 2, "has_more": False,
        "mappings": [{"id": "111", "name": "한글 채널 " + "긴이름 " * 20 + " CHANNEL-END"},
                     {"id": "222", "name": "unbound " + "긴이름 " * 20 + " UNBOUND-MAPPING-END"}],
    })
    return served


def scan(process, fd, output, expected):
    """Page to the end, collecting actual terminal rows, not output history."""
    # The first scan already starts at Home. The renderer does not repaint
    # unchanged scroll state, so settle the key without requiring a new frame.
    h.write_all(fd, output, b"\x1b[H")
    h.drain_until_quiet(process, fd, output)
    seen = set()
    previous = None
    for _ in range(80):
        current = h.screen_text(bytes(output))
        for token in expected:
            if token in current:
                seen.add(token)
        if current == previous:
            break
        previous = current
        h.write_all(fd, output, b"\x1b[6~")
        h.drain_until_quiet(process, fd, output)
    if seen != set(expected):
        raise AssertionError(f"metadata tails unreachable: {set(expected) - seen!r}; {current!r}")
    return current


def run(executable):
    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", "▸Info".encode())
        for columns in (80, 40, 60):
            h.resize_and_wait(process, fd, output, rows=24, columns=columns,
                              needle=b"Keepers", controls=(h.FULL_REDRAW,))
            scan(process, fd, output, (b"segment-END", b"GATE-END", "한글끝".encode(), b"Updated:"))
        for tab in ("Runs", "Automation", "Channels"):
            h.send_and_wait(process, fd, output, b"[", ("▸" + tab).encode())
        h.wait_for_output(process, fd, output, b"Discord", start=0, timeout=15)
        h.drain_until_quiet(process, fd, output)
        for columns in (40, 60, 80):
            h.resize_and_wait(process, fd, output, rows=26, columns=columns,
                              needle=b"Keepers", controls=(h.FULL_REDRAW,))
            scan(process, fd, output, (b"STATUS-PATH-END", b"STORE-PATH-END",
                                      b"ENDPOINT-END", b"ERROR-END", b"CHANNEL-END", b"UNBOUND-MAPPING-END"))
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Keeper metadata wraps into scrollable rows",
                           interact=interact, http_fixtures=fixtures(), prepare_workspace=prepare)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Keeper Info and Channels metadata wrap: PASS")
