"""Lane workspace interaction and raw frames from the CI-built TUI.

The HTTP fixture supplies observations, not a pre-rendered screen. Captures
contain the terminal output produced by the binary after real keyboard input.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import test_tui_keyboard_input as terminal

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names, so without
# this a change to the drawn text below reaches main with no scenario run.
# Three surface titles are masc_tui_render.ml's, the "PARTIAL" badge
# masc_tui_lane_addons.ml's, and the palette row this types
# ("go Lane Add-ons") masc_tui_types.ml's.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui_lane_addons.ml",
    "bin/masc_tui_types.ml",
)


def snapshot() -> dict:
    owner = "35e30f7a-66d1-4e44-a4ed-762be081ee91"
    rows = []
    for index, (lane, title, kind, clock) in enumerate([
        ("browser", "DOM captured", "event", {"domain": "dom", "value": "revision-2"}),
        ("game", "Frame advanced", "event", {"domain": "frame", "value": "154618"}),
        ("statistics", "Value derived", "value", None),
        ("game", "Next day input", "relation", {"domain": "frame", "value": "154619"}),
    ]):
        rows.append({"id": f"{owner}/1/event-{index}", "lane_id": f"{owner}/{lane}",
            "kind": kind, "title": title, "observed_at": 1789257600.0 + (86400 if index == 3 else 0),
            "subject_id": "shared-world", "clock": clock, "actor": "keeper-a" if lane == "game" else None,
            "fields": {"fixture": "concurrent-lanes"}, "evidence": [],
            "related_ids": [f"{owner}/1/event-1", "outside-current-slice"] if index == 3 else []})
    instance = {"instance_id": owner, "run_id": "shared-world", "addon_id": "scene-fixture",
        "title": "World observer", "revision": "1", "phase": {"kind": "attached"},
        "observation_seq": 1, "rows_count": len(rows), "incarnation": owner,
        "configuration": None, "action_schema": None,
        "binding": {"sources": [{"source_id": "frames", "kind": "lane_output",
            "installation_id": "game-producer", "output_id": "frames", "selection": "latest_completed"}]},
        "package": {"outputs": {"world": {"lanes": ["browser", "game", "statistics"]}}, "skills_directory": None}}
    failed = {**instance, "instance_id": "failed-msx", "incarnation": "failed-msx",
        "title": "MSX", "phase": {"kind": "failed",
            "message": "No such image: sha256:" + "4" * 64}}
    return {"instances": [instance, failed], "rows": rows,
        "coverage": [{"source_id": "frames", "incarnation": owner,
            "cursor": "154618", "complete": False, "detail": "producer not observed after this cursor"}],
        "configuration": {"directory": "/fixture/lane-addons", "complete": True, "issues": [], "declarations": []}}


def main(executable: str, captures: Path | None) -> None:
    fixtures = terminal.overview_event_http_fixtures()
    fixtures["/api/v1/lane-addons"] = (200, snapshot())
    requests: terminal.HttpRequests = []

    def interact(process, master, _slave, output, _base):
        def key(value: bytes, needle: bytes) -> bytes:
            return terminal.send_and_wait(process, master, output, value, needle)

        def capture(name: str, rows: int, columns: int) -> None:
            if captures is not None:
                captures.mkdir(parents=True, exist_ok=True)
                (captures / f"{name}.pty").write_bytes(bytes(output))
                (captures / f"{name}.json").write_text(json.dumps({
                    "rows": rows, "columns": columns, "source": "native TUI / controlled HTTP fixture",
                    "screen": name}, indent=2))

        key(b":go lanes\r", b"MASC Lanes")
        palette = key(b":go LANE", b"go Lane Add-ons")
        if b"MASC Lane Add-ons" in terminal.CSI_RE.sub(b"", palette):
            raise AssertionError("uppercase A intercepted palette input")
        key(b"\x1b", b"MASC Lanes")
        key(b"A", b"DOM captured")
        worker_output = key(b"4", b"Horizontal Lane timeline")
        worker_frame = terminal.frame_containing(worker_output, b"Horizontal Lane timeline")
        worker_screen = terminal.screen_text(worker_frame)
        if b"Tab:next pane" not in worker_screen or b"> World observer" not in worker_screen:
            raise AssertionError("Workers compact view lost its pane or selected worker guidance")
        print("TUI_CAPTURE lane-addons Workers compact " + repr(worker_screen), flush=True)
        terminal.resize_and_wait(process, master, output, rows=24, columns=80,
            needle=b"Installed Add-ons", controls=(terminal.FULL_REDRAW,))
        narrow_output = bytes(output)
        needle_at = narrow_output.rfind(b"Installed Add-ons")
        frame_at = narrow_output.rfind(terminal.FRAME_START, 0, needle_at)
        if frame_at < 0:
            raise AssertionError("80-column Lane frame start was not captured")
        narrow_frame = terminal.frame_containing(narrow_output[frame_at:], b"Installed Add-ons")
        plain_narrow = terminal.CSI_RE.sub(b"", narrow_frame)
        expected_hints = b"Esc:back  Tab:Time \xe2\x86\x92 Links \xe2\x86\x92 TOML \xe2\x86\x92 Workers \xe2\x86\x92 Rows  j/k:select  D:details"
        if expected_hints not in plain_narrow:
            raise AssertionError("80-column Lane guidance was cut")
        if b"MSX \xc2\xb7 failed \xc2\xb7 o:retry observation  d:cleanup" not in plain_narrow:
            raise AssertionError("failed instance lost retry or cleanup before its long reason")
        print("TUI_CAPTURE lane-addons 80x24 " + repr(terminal.screen_text(narrow_frame)), flush=True)
        key(b"1", b"DOM captured")
        wide = terminal.resize_and_wait(process, master, output, rows=32, columns=140,
            needle=b"statistics", controls=(terminal.FULL_REDRAW,))
        plain = terminal.CSI_RE.sub(b"", wide)
        for needle in [b"browser", b"game", b"statistics", b"PARTIAL", b"2026-09-13", b"DOM captured", b"Frame advanced"]:
            if needle not in plain:
                raise AssertionError(f"multi-lane screen omitted {needle!r}")
        capture("01-concurrent-timeline", 32, 140)
        key(b"\x1b[C", b"154618")
        key(b" ", b"[x]")
        capture("02-game-clock-marked", 32, 140)
        key(b"j", b"Value derived")
        key(b"j", b"outside-current-slice")
        capture("03-date-and-relations", 32, 140)
        key(b"2", b"game-producer/frames")
        capture("04-source-worker-output", 32, 140)
        key(b"1", b"Next day input")
        narrow = terminal.resize_and_wait(process, master, output, rows=24, columns=64,
            needle=b"Next day input", controls=(terminal.FULL_REDRAW,))
        if b">" not in narrow:
            raise AssertionError("narrow timeline lost selection marker")
        capture("05-narrow-timeline", 24, 64)
        toml_output = key(b"3", b"Installations (E:edit)")
        toml_frame = terminal.frame_containing(toml_output, b"Installations (E:edit)")
        toml_screen = terminal.screen_text(toml_frame)
        if b"Tab:next pane" not in toml_screen or b"No Add-ons installed." not in toml_screen:
            raise AssertionError("TOML compact view lost its pane or empty inventory guidance")
        print("TUI_CAPTURE lane-addons TOML compact " + repr(toml_screen), flush=True)
        os.write(master, b"d")
        # Every POST the fixture sees lands in [requests], and the TUI opens an
        # MCP session of its own at startup ("/mcp" initialize). What this
        # scenario is about is the Add-on surface: browsing it, and pressing d
        # where no detach is offered, must not write to it.
        addon_writes = [entry for entry in requests
                        if entry[0].startswith("/api/v1/lane-addons")]
        if addon_writes:
            raise AssertionError(f"browsing or hidden detach sent mutation: {addon_writes!r}")
        key(b"q", b"MASC Lanes")
        key(b"\x1b", b"MASC Dashboard")
        os.write(master, b"q")

    terminal.run_terminal_scenario(executable, description="Lane visual workspace",
        interact=interact, http_fixtures=fixtures, http_requests=requests)
    print("Lane timeline / clocks / marks / relations / links / resize: PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    main(os.path.abspath(args.executable), args.capture_dir)
