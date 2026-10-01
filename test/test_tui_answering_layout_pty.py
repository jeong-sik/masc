"""Answering keeps lanes visible and lets unavailable-only fleets be read."""
import os
import re
import sys
import time

import tui_keyboard_harness as _keyboard_harness

SOURCE_MODULES = (
    "bin/masc_tui_answering.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui.ml",
    "test/tui_keyboard_harness.py",
)


def current_rows(output):
    return list(_keyboard_harness.screen_rows(bytes(output[:output.rfind(_keyboard_harness.FRAME_END) + len(_keyboard_harness.FRAME_END)])).values())


def run(executable):
    names = ["long-" + "keeper" * 24, "한글이름" * 30, "alpha"]
    started = time.time() - 120
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/turns"] = (200, {
        "schema": "masc.keeper_turns.v1",
        "keepers": [{"keeper_name": name, "status": "ok", "turn": {
            "lane": "chat_operation", "started_at_unix": started,
            "interrupt_token": "answering-fixture-token",
            "preview": {"status_text": "PREVIEW working", "text_tail": "visible output",
                        "updated_at_unix": started, "last_tool": None},
        }} for name in names],
    })

    def inspect_running(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.send_and_wait(process, master_fd, output, b"@", b"PREVIEW")
        for width in (60, 80, 120):
            _keyboard_harness.resize_and_wait(process, master_fd, output, rows=26, columns=width,
                              needle=b"MASC Answering", final_cursor=b"\x1b[?25l")
            _keyboard_harness.drain_until_quiet(process, master_fd, output)
            rows = current_rows(output)
            running = [row for row in rows if b"chat_operation" in row]
            assert len(running) == 3, (width, rows)
            for row in running:
                assert re.search(rb"chat_operation +2m[0-9]+s", row), (width, row)
            assert any(b"alpha" in row for row in running), (width, rows)
            assert any(b"long-" in row for row in running), (width, rows)
            assert any("한글".encode() in row for row in running), (width, rows)
            assert any(b"PREVIEW" in row for row in rows), (width, rows)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Answering fits long ASCII and CJK names without losing lane or age",
                            interact=inspect_running, http_fixtures=fixtures)

    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/turns"] = (200, {
        "schema": "masc.keeper_turns.v1",
        "keepers": [{"keeper_name": f"unavailable-{i:02d}", "status": "unavailable",
                     "detail": f"owner read failed {i:02d}"} for i in range(40)],
    })

    def inspect_unavailable(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.resize_and_wait(process, master_fd, output, rows=26, columns=60,
                          needle=b"MASC Dashboard", final_cursor=b"\x1b[?25l")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"@", b"owner read failed 00")
        # There are no actionable rows. j still moves the reading window.
        _keyboard_harness.send_and_wait(process, master_fd, output, b"j" * 40, b"owner read failed 39")
        _keyboard_harness.drain_until_quiet(process, master_fd, output)
        assert any(b"owner read failed 39" in row for row in current_rows(output))
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b[H", b"owner read failed 00")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b[6~", b"owner read failed 20")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b[F", b"owner read failed 39")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b[5~", b"owner read failed 10")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Answering scrolls unavailable rows with movement, page and edge keys",
                            interact=inspect_unavailable, http_fixtures=fixtures)

    for page_key, move_key, target in ((b"\x1b[6~", b"j", b"beta"),
                                      (b"\x1b[F", b"k", b"alpha")):
        fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
        fixtures["/api/v1/keepers/turns"] = (200, {
            "schema": "masc.keeper_turns.v1",
            "keepers": [{"keeper_name": name, "status": "ok", "turn": {
                "lane": "chat_operation", "started_at_unix": started,
                "interrupt_token": "answering-fixture-token",
                "preview": {"status_text": "PREVIEW " + name,
                            "text_tail": "visible output", "updated_at_unix": started,
                            "last_tool": None},
            }} for name in ["alpha", "beta"] + [f"runner-{i:02d}" for i in range(2, 40)]],
        })

        def inspect_paged_selection(process, master_fd, _slave_fd, output, _base_path):
            _keyboard_harness.resize_and_wait(process, master_fd, output, rows=26, columns=80,
                              needle=b"MASC Dashboard", final_cursor=b"\x1b[?25l")
            _keyboard_harness.send_and_wait(process, master_fd, output, b"@", b"PREVIEW alpha")
            _keyboard_harness.send_and_wait(process, master_fd, output, page_key,
                            b"live preview \xe2\x80\x94 none for this row")
            _keyboard_harness.drain_until_quiet(process, master_fd, output)
            rows = current_rows(output)
            assert any(b"chat_operation" in row for row in rows), rows
            assert not any(b"\xe2\x96\xb8" in row and b"chat_operation" in row
                           for row in rows), rows
            assert not any(b"PREVIEW alpha" in row for row in rows), rows
            os.write(master_fd, b"\r")
            _keyboard_harness.drain_until_quiet(process, master_fd, output)
            assert any(b"MASC Answering" in row for row in current_rows(output)), current_rows(output)
            # Movement follows the retained cursor back into the window.
            _keyboard_harness.send_and_wait(process, master_fd, output, move_key, b"PREVIEW " + target)
            _keyboard_harness.drain_until_quiet(process, master_fd, output)
            rows = current_rows(output)
            assert any(target in row and b"\xe2\x96\xb8" in row and b"chat_operation" in row
                       for row in rows), rows
            _keyboard_harness.send_and_wait(process, master_fd, output, b"\r",
                            b"Keepers \xe2\x96\xb8 " + target + b" \xe2\x96\xb8 chat")
            _keyboard_harness.drain_until_quiet(process, master_fd, output)
            assert not any(b"MASC Answering" in row for row in current_rows(output)), current_rows(output)
            # In chat q belongs to the draft. Leave chat before asking to quit.
            _keyboard_harness.escape_to_keeper_detail(process, master_fd, output, name=target)
            os.write(master_fd, b"q")

        _keyboard_harness.run_terminal_scenario(executable,
            description="Answering ignores invisible Enter then follows " + move_key.decode() + " back to a visible target",
            interact=inspect_paged_selection, http_fixtures=fixtures)
    print("tui answering layout: PASS")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_answering_layout_pty.py <masc_tui.exe>")
    run(sys.argv[1])
