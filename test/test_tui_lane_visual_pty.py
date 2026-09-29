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

        def screen(data: bytes, needle: bytes) -> bytes:
            return terminal.screen_text(terminal.frame_containing(data, needle))

        def capture(name: str, rows: int, columns: int) -> None:
            if captures is not None:
                captures.mkdir(parents=True, exist_ok=True)
                (captures / f"{name}.pty").write_bytes(bytes(output))
                (captures / f"{name}.json").write_text(json.dumps({
                    "rows": rows, "columns": columns,
                    "source": "native TUI / controlled HTTP fixture", "screen": name,
                }, indent=2))

        key(b":go lanes\r", b"MASC Lanes")
        palette = key(b":go LANE", b"go Lane Add-ons")
        if b"MASC Lane Add-ons" in terminal.CSI_RE.sub(b"", palette):
            raise AssertionError("uppercase A intercepted palette input")
        key(b"\x1b", b"MASC Lanes")
        overview = key(b"A", b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 1 active \xc2\xb7 1 failed")
        first = screen(overview, b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 1 active \xc2\xb7 1 failed")
        for needle in (b"> World observer", b"MSX", b"o:retry observation",
                       b"d:cleanup", b"D:full"):
            if needle not in first:
                raise AssertionError(f"Add-on overview omitted {needle!r}")
        print("TUI_CAPTURE lane-addons overview " + repr(first), flush=True)
        capture("01-overview-100", 30, 100)

        heading = b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 1 active \xc2\xb7 1 failed"
        resized = terminal.resize_and_wait(process, master, output, rows=24, columns=80,
            needle=heading, controls=(terminal.FULL_REDRAW,))
        resize_at = len(output) - len(resized)
        needle_at = output.find(heading, resize_at)
        needle_end = needle_at + len(heading)
        terminal.wait_for_output(process, master, output, terminal.FRAME_END,
            start=needle_end, timeout=3.0)
        frame_end = output.find(terminal.FRAME_END, needle_end) + len(terminal.FRAME_END)
        frame_at = output.rfind(terminal.FRAME_START, 0, needle_at)
        if frame_at < 0:
            raise AssertionError("80-column Lane frame start was not captured")
        narrow_frame = terminal.frame_containing(bytes(output[frame_at:frame_end]), heading)
        narrow_screen = terminal.screen_text(narrow_frame)
        if b"Enter:open" not in narrow_screen or b"D:full" not in narrow_screen:
            raise AssertionError("80-column overview lost navigation or full failure path")
        if b"sha256:" + b"4" * 64 not in narrow_screen:
            raise AssertionError("80-column overview cut the failed image identifier")
        print("TUI_CAPTURE lane-addons 80x24 " + repr(narrow_screen), flush=True)
        capture("02-overview-80", 24, 80)

        help_output = key(b"?", b"Lane Add-ons keys")
        help_screen = screen(help_output, b"Lane Add-ons keys")
        for needle in (b"Esc:close", b"j/k select", b"Enter open", b"1 Activity",
                       b"4 Records", b"E edit", b"e export marked rows", b":act"):
            if needle not in help_screen:
                raise AssertionError(f"Lane help omitted {needle!r}")
        key(b"\x1b", b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 1 active \xc2\xb7 1 failed")
        os.write(master, b"\t")
        if not terminal.drain_until_quiet(process, master, output):
            raise AssertionError("overview did not settle after Tab")
        detail = key(b"\r", b"1 Activity")
        activity = screen(detail, b"1 Activity")
        for needle in (b"World observer", b"DOM captured", b"Frame advanced"):
            if needle not in activity:
                raise AssertionError(f"Activity omitted {needle!r}")
        capture("03-activity-80", 24, 80)
        key(b"2", b"Input: game-producer/frames")
        key(b"3", b"Revision: 1")
        records = key(b"4", b"Value derived")
        if b"Row " not in screen(records, b"Value derived"):
            raise AssertionError("Records omitted row identities")

        wide = terminal.resize_and_wait(process, master, output, rows=32, columns=140,
            needle=b"Value derived", controls=(terminal.FULL_REDRAW,))
        capture("04-records-140", 32, 140)

        os.write(master, b"jjj")
        if not terminal.drain_until_quiet(process, master, output):
            raise AssertionError("Records did not settle after moving selection")
        technical = key(b"D", b"Rows")
        if b"outside-current-slice" not in technical:
            raise AssertionError("raw Records lost declared relations")
        key(b"\x1b", b"4 Records")
        timeline = key(b"1", b"Horizontal Lane timeline")
        plain = terminal.CSI_RE.sub(b"", timeline)
        for needle in (b"browser", b"game", b"statistics", b"PARTIAL",
                       b"2026-09-13", b"DOM captured", b"Frame advanced"):
            if needle not in plain:
                raise AssertionError(f"Activity timeline omitted {needle!r}")
        capture("05-activity-timeline-140", 32, 140)
        key(b"\x1b", b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 1 active \xc2\xb7 1 failed")
        empty = snapshot()
        empty["instances"] = []
        empty["rows"] = []
        fixtures["/api/v1/lane-addons"] = (200, empty)
        empty_output = key(b"r", b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 0 active \xc2\xb7 0 failed")
        empty_screen = screen(empty_output, b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 0 active \xc2\xb7 0 failed")
        if b"No Add-ons declared or active. i:install a package  n:new TOML" not in empty_screen:
            raise AssertionError("empty Add-on workspace lacks a next step")
        capture("06-empty-140", 32, 140)
        os.write(master, b"d")
        addon_writes = [entry for entry in requests
                        if entry[0].startswith("/api/v1/lane-addons")]
        if addon_writes:
            raise AssertionError(f"browsing or hidden detach sent mutation: {addon_writes!r}")
        key(b"q", b"MASC Lanes")
        key(b"\x1b", b"MASC Overview")
        os.write(master, b"q")

    terminal.run_terminal_scenario(executable, description="Lane visual workspace",
        interact=interact, http_fixtures=fixtures, http_requests=requests)
    print("Lane timeline / clocks / marks / relations / links / resize: PASS")


def run_declaration_without_worker(executable: str) -> None:
    fixtures = terminal.overview_event_http_fixtures()
    fixtures["/api/v1/lane-addons"] = (200, {
        "instances": [], "rows": [], "coverage": [],
        "configuration": {
            "directory": "/fixture/lane-addons", "complete": False,
            "declarations": [{"id": "broken", "source_path": "/fixture/lane-addons/broken.toml",
                              "desired_revision": "r1", "applied_revision": None,
                              "instance_id": None}],
            "issues": [{"id": "broken", "source_path": "/fixture/lane-addons/broken.toml",
                        "message": "Docker image missing"}],
        },
    })
    requests: terminal.HttpRequests = []

    def interact(process, master, _slave, output, _base):
        terminal.wait_for_output(process, master, output, b"Health: ", start=0, timeout=10)
        overview = terminal.send_and_wait(process, master, output, b":go lane add-ons\r",
                                          b"1 declared \xc2\xb7 0 active")
        shown = terminal.screen_text(overview)
        for needle in (b"> broken", b"needs attention", b"Installation inventory partial"):
            if needle not in shown:
                raise AssertionError(f"unapplied declaration is hidden: {needle!r}")
        terminal.send_and_wait(process, master, output, b"a", b"no available worker")
        terminal.send_and_wait(process, master, output, b"\r", b"Installation details")
        terminal.send_and_wait(process, master, output, b"\x1b", b"> broken")
        fixtures["/api/v1/lane-addons"] = (200, {
            "instances": [], "rows": [], "coverage": [],
            "configuration": {"directory": "/fixture/lane-addons", "complete": False,
                              "declarations": [],
                              "issues": [{"id": None, "source_path": "/fixture/lane-addons",
                                          "message": "directory unavailable"}]},
        })
        issue = terminal.send_and_wait(process, master, output, b"r",
                                       b"0 declared \xc2\xb7 0 active")
        shown = terminal.screen_text(terminal.frame_containing(issue, b"0 declared"))
        if b"Installations and configuration problems" not in shown or b"No Add-ons declared" in shown:
            raise AssertionError("directory-only issue was displayed as an empty installation")
        if b"E:edit" in shown:
            raise AssertionError("directory issue advertised editing a missing TOML file")
        fixtures["/api/v1/lane-addons"] = (200, {
            "instances": [], "rows": [], "coverage": [],
            "configuration": {"directory": "/fixture/lane-addons", "complete": True,
                              "declarations": [{"id": "good", "source_path": "/fixture/lane-addons/good.toml",
                                                "desired_revision": "r1", "applied_revision": None,
                                                "instance_id": None}],
                              "issues": [{"id": None, "source_path": "/fixture/lane-addons/broken.toml",
                                          "message": "invalid TOML"}]},
        })
        mixed = terminal.send_and_wait(process, master, output, b"r", b"1 declared \xc2\xb7 0 active")
        shown = terminal.screen_text(terminal.frame_containing(mixed, b"1 declared"))
        good_at = shown.find(b"good \xc2\xb7 pending")
        broken_at = shown.find(b"broken.toml \xc2\xb7 configuration issue")
        if good_at < 0 or broken_at < 0 or good_at >= broken_at:
            raise AssertionError("display order differs from configuration navigation")
        terminal.send_and_wait(process, master, output, b"j", b"> good")
        terminal.send_and_wait(process, master, output, b"j", b"> broken.toml")
        detail = terminal.send_and_wait(process, master, output, b"\r", b"Installation details \xc2\xb7 broken.toml")
        if b"E:edit TOML" not in terminal.screen_text(detail):
            raise AssertionError("malformed TOML detail omitted the repair path")
        terminal.send_and_wait(process, master, output, b"\x1b", b"> broken.toml")
        os.write(master, b"q")

    terminal.run_terminal_scenario(executable,
        description="unapplied declaration opens Installation and refuses worker action",
        interact=interact, http_fixtures=fixtures, http_requests=requests)
    if any(path.startswith("/api/v1/lane-addons") for path, _ in requests):
        raise AssertionError("browse-only declaration scenario sent a write")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    main(os.path.abspath(args.executable), args.capture_dir)
    run_declaration_without_worker(os.path.abspath(args.executable))
