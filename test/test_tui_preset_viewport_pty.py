"""Preset contents and failed restore evidence survive physical-row paging."""
import json
import os
import re
import sys
import threading

import test_tui_keyboard_input as h


DESCRIPTION = "DESCHEAD " + "한 preset description " * 14 + " DESCEND"
DIRECTORY = "/fixture/presets/" + "deep-directory/" * 12 + "DIRECTORYEND"
KEY = "prompt." + "long-key-" * 16 + "KEYEND"
KEEPER = "keeper-" + "delegated-" * 15 + "KEEPEREND"
PATH = "/fixture/prompts/" + "nested-source/" * 14 + "PATHEND.md"
REASON = "Restore rejected because " + "typed source disagrees " * 12 + "REASONEND"
ERROR = "Unreadable manifest " + "check saved source " * 14 + "ERRORRECOVERYEND"
REFRESH_ERROR = "Refresh refused " + "inspect fixture source " * 10 + "REFRESHEND"
WINDOW = re.compile(rb"\[lines (\d+)-(\d+)/(\d+)\]")


def screen(output):
    end = output.rfind(h.FRAME_END)
    rows = h.screen_rows(bytes(output[:end + len(h.FRAME_END)]))
    return b"\n".join(rows[key] for key in sorted(rows))


def compact(value):
    return b"".join(h.unwrapped(value).split())


def window(output):
    found = WINDOW.search(screen(output))
    assert found is not None, screen(output)
    return tuple(int(group) for group in found.groups())


def run(executable, no_color):
    manifest = {"schema_version": 1, "name": "layout-proof", "description": DESCRIPTION,
                "created_at": "2026-09-30T01:00:00Z", "override_count": 1,
                "override_keys": [KEY], "keepers": [KEEPER], "assignment_count": 1, "lane_count": 1}
    snapshot = {"ok": True, "presets": [manifest],
                "unreadable": [{"name": "unreadable", "reason": ERROR}]}
    detail = {"directory": DIRECTORY, "saved_settings": {"status": "matches"},
              "prompt_files": [{"key": KEY, "path": PATH, "source": "override"}],
              "preset": {"name": "layout-proof", "prompt_overrides": [{"key": KEY, "bytes": 30}],
                         "instructions": [{"keeper_file": KEEPER, "bytes": 40}],
                         "assignments": [{"keeper": KEEPER, "runtime": "fixture-runtime"}],
                         "lanes": [{"id": "fixture-lane"}]}}
    report = {"ok": True, "report": {"restored": "layout-proof", "autosave": "fixture-autosave",
              "prompt_overrides": {"effect": "partial", "applied": [],
                                   "skipped": [{"key": KEY, "reason": REASON}]},
              "instructions": {"effect": "unchanged", "applied": [], "skipped": []},
              "runtime": {"status": "failed", "error": REASON}}}
    failed = threading.Event()
    reordered = threading.Event()
    hold_detail = threading.Event()
    detail_entered = threading.Event()
    detail_released = threading.Event()
    def shown_detail():
        if hold_detail.is_set():
            detail_entered.set()
            assert detail_released.wait(10), "test did not release detail response"
        return 200, detail
    other = dict(manifest, name="other-preset", description="Another preset")
    reloaded = dict(snapshot, presets=[other, manifest])
    fixtures = h.overview_event_http_fixtures()
    fixtures["/api/v1/presets"] = lambda: ((503, {"error": REFRESH_ERROR})
                                            if failed.is_set() else
                                            (200, reloaded if reordered.is_set() else snapshot))
    fixtures["/api/v1/presets/show?name=layout-proof"] = shown_detail
    fixtures["/api/v1/presets/show?name=other-preset"] = (200, dict(detail,
        directory="/fixture/unselected/OTHERONLY", preset=dict(detail["preset"], name="other-preset")))
    fixtures["/api/v1/presets/restore"] = (200, report)
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.resize_and_wait(process, fd, output, rows=220, columns=80,
                          needle=b"Dashboard", final_cursor=b"\x1b[?25l")
        h.palette_go(process, fd, output, b"go System", b"runtime.toml")
        for _ in range(4):
            h.press_and_settle(process, fd, output, b"p")
        h.wait_for_output(process, fd, output, b"DIRECTORYEND", start=0, timeout=10)
        h.drain_until_quiet(process, fd, output)
        # A fresh registry may insert a row before the selected preset. The
        # operator's restore must still name the preset they were reading.
        reordered.set()
        h.send_and_wait(process, fd, output, b"r", b"other-preset")
        h.drain_until_quiet(process, fd, output)
        assert b"Selected:layout-proof" in compact(screen(output)), screen(output)
        # Restoration is entirely synthetic HTTP. Its skipped keys and
        # failed runtime commit are evidence the detail must never abbreviate.
        h.press_and_settle(process, fd, output, b"u")
        assert not any(path == "/api/v1/presets/restore" for path, _ in requests)
        h.send_and_wait(process, fd, output, b"u", b"REASONEND")
        h.drain_until_quiet(process, fd, output)
        restored = [json.loads(body) for path, body in requests if path == "/api/v1/presets/restore"]
        assert restored == [{"name": "layout-proof"}], restored
        for width in (40, 60, 80, 120):
            h.resize_and_wait(process, fd, output, rows=220, columns=width,
                              needle=b"DESCHEAD", final_cursor=b"\x1b[?25l")
            h.drain_until_quiet(process, fd, output)
            reading = compact(screen(output))
            for value in (DESCRIPTION, DIRECTORY, KEY, KEEPER, PATH, REASON, ERROR):
                assert compact(value.encode()) in reading, (width, value, reading)
            h.resize_and_wait(process, fd, output, rows=18, columns=width,
                              needle=b"DESCHEAD", final_cursor=b"\x1b[?25l")
            h.drain_until_quiet(process, fd, output)
            first, last, total = window(output)
            assert first == 1 and last < total, (first, last, total)
            h.press_and_settle(process, fd, output, b"\x1b[6~")
            after, _last, count = window(output)
            assert after == first + max(1, last - first) and count == total, (first, last, after, count)
            h.press_and_settle(process, fd, output, b"\x1b[5~")
            assert window(output)[0] == 1, window(output)
            h.send_and_wait(process, fd, output, b"\x1b[F", b"ERRORRECOVERYEND")
            h.drain_until_quiet(process, fd, output)
            start, end, count = window(output)
            assert start > 1 and end == count, (start, end, count)
            h.press_and_settle(process, fd, output, b"\x1b[5~")
            assert window(output)[0] < start, "scroll did not return immediately from End"
            h.send_and_wait(process, fd, output, b"\x1b[H", b"DESCHEAD")
        # Refetching the same preset retains its full document while the
        # response is held. Otherwise a loading-only frame clamps End away.
        h.send_and_wait(process, fd, output, b"\x1b[F", b"ERRORRECOVERYEND")
        h.drain_until_quiet(process, fd, output)
        held_window = window(output)
        hold_detail.set()
        os.write(fd, b"r")
        try:
            assert h.wait_for_fixture_event(process, fd, output, detail_entered, timeout=5), "same-name refresh did not refetch detail"
            # Inspect refresh-era frames, rather than an unchanged old End
            # frame that happened to be quiet before the renderer ran.
            h.send_and_wait(process, fd, output, b"\x1b[H", b"DESCHEAD")
            h.send_and_wait(process, fd, output, b"\x1b[F", b"ERRORRECOVERYEND")
            h.drain_until_quiet(process, fd, output)
            assert window(output) == held_window, (held_window, window(output))
            assert b"ERRORRECOVERYEND" in screen(output), screen(output)
        finally:
            detail_released.set()
        h.send_and_wait(process, fd, output, b"\x1b[H", b"DESCHEAD")
        # Refresh keeps the selected row, full detail and report, with one
        # failure row outside the list. The end hint remains inside 18 rows.
        failed.set()
        h.send_and_wait(process, fd, output, b"r", b"Refresh failed:")
        h.drain_until_quiet(process, fd, output)
        rows = h.screen_rows(bytes(output))
        assert max(rows) <= 18, rows
        assert b"layout-proof" in screen(output), screen(output)
        assert b"Home/End" in screen(output), screen(output)
        h.resize_and_wait(process, fd, output, rows=220, columns=40,
                          needle=b"REFRESHEND", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, fd, output)
        reading = compact(screen(output))
        for value in (REFRESH_ERROR, DIRECTORY, DESCRIPTION, REASON):
            assert compact(value.encode()) in reading, (value, reading)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Preset physical-row detail and retained refresh"
                            + (" NO_COLOR" if no_color else ""), interact=interact,
                            http_fixtures=fixtures, http_requests=requests,
                            extra_env={"NO_COLOR": "1"} if no_color else {})


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    run(executable, False)
    run(executable, True)
    print("Preset physical-row viewport: PASS")
