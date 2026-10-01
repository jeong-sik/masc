"""Lane workspace interaction and raw frames from the CI-built TUI.

The HTTP fixture supplies observations, not a pre-rendered screen. Captures
contain the terminal output produced by the binary after real keyboard input.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
from pathlib import Path

import test_tui_keyboard_input as terminal

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names, so without
# this a change to the drawn text below reaches main with no scenario run.
# Three surface titles are masc_tui_render.ml's, the "PARTIAL" badge
# masc_tui_lane_addons.ml's, and the palette row this types
# ("go Lane Add-ons") masc_tui_types.ml's.
SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_keys.ml",
    "lib/tui_terminal_text.ml",
    "lib/tui_terminal_text.mli",
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
        overview = key(b"A", b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 1 active \xc2\xb7 1 failed workers")
        first = screen(overview, b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 1 active \xc2\xb7 1 failed workers")
        for needle in (b"> World observer", b"MSX", b"o:retry observation",
                       b"d:cleanup", b"D:full"):
            if needle not in first:
                raise AssertionError(f"Add-on overview omitted {needle!r}")
        print("TUI_CAPTURE lane-addons overview " + repr(first), flush=True)
        capture("01-overview-100", 30, 100)

        heading = b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 1 active \xc2\xb7 1 failed workers"
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
        for needle in (b"Esc:close", b"j/k select", b"Enter open", b"1 Results",
                       b"4 Records", b"E edit", b"e export marked rows", b"A command"):
            if needle not in help_screen:
                raise AssertionError(f"Lane help omitted {needle!r}")
        key(b"\x1b", b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 1 active \xc2\xb7 1 failed workers")
        os.write(master, b"\t")
        if not terminal.drain_until_quiet(process, master, output):
            raise AssertionError("overview did not settle after Tab")
        detail = key(b"\r", b"1 Results")
        activity = screen(detail, b"1 Results")
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
        technical = key(b"D", b"Raw details")
        raw_screen = screen(technical, b"Raw details")
        if b"outside-current-slice" not in raw_screen:
            raise AssertionError("raw Records lost the selected row's declared relations")
        if b"3 TOML" in raw_screen or b"4 Workers" in raw_screen or b"5 Rows" in raw_screen:
            raise AssertionError("raw detail reopened the retired five-tab screen")
        key(b"\x1b", b"4 Records")
        timeline = key(b"1", b"Activity timeline")
        plain = terminal.CSI_RE.sub(b"", timeline)
        for needle in (b"browser", b"game", b"statistics", b"PARTIAL",
                       b"2026-09-14", b"DOM captured", b"Frame advanced"):
            if needle not in plain:
                raise AssertionError(f"Activity timeline omitted {needle!r}")
        capture("05-activity-timeline-140", 32, 140)
        key(b"\x1b", b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 1 active \xc2\xb7 1 failed workers")
        empty = snapshot()
        empty["instances"] = []
        empty["rows"] = []
        fixtures["/api/v1/lane-addons"] = (200, empty)
        empty_output = key(b"r", b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 0 active \xc2\xb7 0 failed workers")
        empty_screen = screen(empty_output, b"Lane Add-ons \xc2\xb7 0 declared \xc2\xb7 0 active \xc2\xb7 0 failed workers")
        if b"No Add-ons installed. i:install a package  n:new TOML" not in empty_screen:
            raise AssertionError("empty Add-on workspace lacks a next step")
        capture("06-empty-140", 32, 140)
        os.write(master, b"d")
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


def run_installation_detail(executable: str) -> None:
    fixtures = terminal.overview_event_http_fixtures()
    fixtures["/api/v1/lane-addons"] = (200, {
        "instances": [], "rows": [], "coverage": [],
        "configuration": {"directory": "/fixture/lane-addons", "complete": False,
                          "declarations": [{"id": "broken", "source_path": "/fixture/lane-addons/broken.toml",
                                            "desired_revision": "r1", "applied_revision": None,
                                            "instance_id": None}],
                          "issues": [{"id": "broken", "source_path": "/fixture/lane-addons/broken.toml",
                                      "message": "Docker image missing"}]},
    })
    requests: terminal.HttpRequests = []

    def interact(process, master, _slave, output, _base):
        terminal.wait_for_output(process, master, output, b"Health: ", start=0, timeout=10)
        overview = terminal.send_and_wait(process, master, output, b":go lane add-ons\r",
                                          b"1 declared")
        if b"> broken" not in terminal.screen_text(overview):
            raise AssertionError("unapplied installation was not selected")
        terminal.send_and_wait(process, master, output, b"a", b"no available worker")
        detail = terminal.send_and_wait(process, master, output, b"\r",
                                        b"Installation details \xc2\xb7 broken")
        screen = terminal.screen_text(detail)
        if b"Esc:back  E:edit TOML" not in screen or b"Docker image missing" not in screen:
            raise AssertionError("focused Installation detail omitted repair context")
        returned = terminal.send_and_wait(process, master, output, b"\x1b", b"> broken")
        if b"1 declared" not in terminal.screen_text(returned):
            raise AssertionError("Esc did not return to the same Installation list")
        terminal.send_and_wait(process, master, output, b"q", b"MASC Dashboard")
        os.write(master, b"q")

    terminal.run_terminal_scenario(executable,
        description="unapplied Installation detail preserves edit and return path",
        interact=interact, http_fixtures=fixtures, http_requests=requests)
    if any(path.startswith("/api/v1/lane-addons") for path, _ in requests):
        raise AssertionError("browse-only Installation detail sent a write")
    print("Lane Add-on Installation detail: PASS")


def run_navigation_consistency(executable: str) -> None:
    fixtures = terminal.overview_event_http_fixtures()
    fixtures["/api/v1/lane-addons"] = (200, snapshot())

    def interact(process, master, _slave, output, _base):
        def key(value, needle):
            return terminal.send_and_wait(process, master, output, value, needle)

        def capture(name, frame):
            drawn = bytes(output)
            frame = drawn[drawn.rfind(terminal.FULL_REDRAW):]
            print("STUDIO_CAPTURE=" + json.dumps({
                "suite": "test_tui_lane_visual_pty", "name": name, "rows": 30, "columns": 100,
                "provenance": "CI fixture PTY",
                "frame_b64": base64.b64encode(frame).decode(),
                "screen": b"\n".join(terminal.screen_rows(frame).get(row, b"") for row in range(1, 31)).decode(errors="replace")}), flush=True)

        terminal.wait_for_output(process, master, output, b"Health: ", start=0, timeout=10)
        for name in (b"Dashboard", b"Work", b"Keepers", b"Usage", b"Board", b"Workspace", b"System"):
            title = b"MASC " + name
            key(b":go " + name + b"\r", title)
            palette = key(b":", b"From " + name)
            capture("palette-from-" + name.decode().lower(), palette)
            key(b"\x1b", title)
        key(b":go Dashboard\r", b"MASC Dashboard")
        initial = key(b":go ", re.compile(rb":(?:\x1b\[[0-9;]*m)* go "))
        counts = re.findall(rb"(\d+) commands .*? (\d+)/(\d+)", terminal.screen_text(initial))
        if not counts:
            raise AssertionError("palette did not expose selection position")
        total = int(counts[-1][2])
        if total < 2:
            raise AssertionError("fixture has no second navigation candidate")
        key(b"\x1b[B" * (total + 3), f"{total}/{total}".encode())
        key(b"\x1b[A", f"{total - 1}/{total}".encode())
        key(b"\x1b[H", f"1/{total}".encode())
        key(b"\x1b[F", f"{total}/{total}".encode())
        key(b"\x15", b"type to filter")
        key(b"zzzz_no_destination", b"No matching command")
        key(b"\r", b"MASC Dashboard")
        preview = key(b":def explicit_symbol", b"definition explicit_symbol")
        capture("palette-code-question", preview)
        if b"Ask about this symbol" not in terminal.screen_text(preview):
            raise AssertionError("typed Code action has no execution preview")
        key(b"\r", b"hover, def and refs ask about the file open")
        key(b":go lane add-ons\r", b"World observer")
        capture("palette-from-addons", key(b":", b"From Lane Add-ons"))
        key(b"\x1b", b"World observer")
        draft = key(b"A::act", b":::act")
        if b"MASC Command palette" in terminal.screen_text(draft):
            raise AssertionError("advanced text input intercepted a literal colon")
        key(b"\x1b", b"World observer")
        key(b":go Board\r", b"MASC Board")
        key(b":go Dashboard\r", b"MASC Dashboard")
        os.write(master, b"q")

    terminal.run_terminal_scenario(executable,
        description="palette navigation preserves origin, clamps selection and escapes Add-ons",
        interact=interact, http_fixtures=fixtures, workspace="Navigation fixture")
    print("TUI navigation consistency: PASS")


def run_declared_report(executable: str, captures: Path | None) -> None:
    fixtures = terminal.overview_event_http_fixtures()
    captured = snapshot()
    instance = captured["instances"][0]
    instance["title"] = "Analysis report"
    instance["package"]["presentation"] = {
        "description": "Read analysis and retain its sources",
        "readings": [
            {"lane_id": "report", "path": ["body"], "label": "Report", "format": "text"},
            {"lane_id": "report", "path": ["input_complete"], "label": "Input complete", "format": "boolean"},
            {"lane_id": "report", "path": ["delivery_status"], "label": "Delivery", "format": "text"},
        ],
    }
    captured["instances"] = [instance]
    captured["rows"] = [{**captured["rows"][0], "lane_id": instance["instance_id"] + "/report",
        "title": "Retained analysis", "fields": {"body": "Useful finding\r\nNext agent action",
            "input_complete": False, "delivery_status": "not attempted"}}]
    captured["rows"].append({**captured["rows"][0], "id": instance["instance_id"] + "/1/second",
        "observed_at": captured["rows"][0]["observed_at"] + 1,
        "title": "Second analysis", "fields": {"body": "Other finding\r\nSecond agent action\rstandalone\r",
            "input_complete": True, "delivery_status": "not attempted"}})
    ordinary = {**captured["rows"][0], "id": instance["instance_id"] + "/1/ordinary",
        "lane_id": instance["instance_id"] + "/grades", "observed_at": 0,
        "title": "Ordinary grade", "fields": {"grade": "incorrect"}}
    # Producer order differs from chronological navigation; initial opening
    # must find the declared report after the ordinary observation.
    first, second = captured["rows"]
    captured["rows"] = [second, ordinary, first]
    instance["rows_count"] = 3
    for index in range(1, 7):
        captured["instances"].append({**instance,
            "instance_id": f"selection-worker-{index}", "title": f"Worker selection {index}",
            "rows_count": 0, "package": {**instance["package"], "presentation": {
                "description": f"Worker {index} purpose " * 40, "readings": []}}})
    fixtures["/api/v1/lane-addons"] = (200, captured)
    requests: terminal.HttpRequests = []

    def interact(process, master, _slave, output, _base):
        terminal.wait_for_output(process, master, output, b"Health: ", start=0, timeout=10)
        terminal.send_and_wait(process, master, output, b":go lane add-ons\r",
                               b"Read analysis and retain its sources")
        detail = terminal.send_and_wait(process, master, output, b"\r", b"Delivery: not attempted")
        screen = terminal.screen_text(terminal.frame_containing(detail, b"Delivery: not attempted"))
        for needle in (b"Report: Useful finding", b"Next agent action", b"Input complete: false"):
            if needle not in screen:
                raise AssertionError(f"declared report omitted {needle!r}: {screen!r}")
        if b"\\nNext agent action" in screen or b"\\x0D" in screen:
            raise AssertionError("report body corrupted its line endings")
        print("TUI_CAPTURE declared-report " + repr(screen), flush=True)
        if captures is not None:
            captures.mkdir(parents=True, exist_ok=True)
            (captures / "07-declared-report.pty").write_bytes(bytes(output))
        changed = terminal.send_and_wait(process, master, output, b"j", b"Report: Other finding")
        changed_screen = terminal.screen_text(terminal.frame_containing(changed, b"Report: Other finding"))
        if b"> Second analysis" not in changed_screen or b"Report: Useful finding" in changed_screen:
            raise AssertionError(f"report navigation hid the selected body: {changed_screen!r}")
        if b"Second agent action\\x0Dstandalone\\x0D" not in changed_screen:
            raise AssertionError(f"standalone carriage returns were hidden: {changed_screen!r}")
        terminal.send_and_wait(process, master, output, b"D", b"Raw details")
        terminal.send_and_wait(process, master, output, b"\x1b", b"Report: Other finding")
        terminal.send_and_wait(process, master, output, b"\x1b", b"Analysis report")
        terminal.resize_and_wait(process, master, output, rows=18, columns=40,
                                 needle=b"Analysis report", controls=(terminal.FULL_REDRAW,))
        for index in range(1, 7):
            terminal.press_and_settle(process, master, output, b"j")
            selected_screen = terminal.screen_text(bytes(output))
            marker = f"> Worker selection {index}".encode()
            if marker not in selected_screen:
                raise AssertionError(f"selected Add-on hidden behind earlier descriptions: {selected_screen!r}")
        terminal.press_and_settle(process, master, output, b"JJJJJJJJJJ")
        terminal.press_and_settle(process, master, output, b"k")
        if b"> Worker selection 5" not in terminal.screen_text(bytes(output)):
            raise AssertionError("selection did not reset the previous description scroll")
        terminal.send_and_wait(process, master, output, b"q", b"MASC Dashboard")
        os.write(master, b"q")

    terminal.run_terminal_scenario(executable, description="declared report content and separate delivery",
        interact=interact, http_fixtures=fixtures, http_requests=requests)
    if any(path.startswith("/api/v1/lane-addons") for path, _ in requests):
        raise AssertionError("report reading sent an Add-on mutation")
    print("Lane declared report body / partial input / separate delivery: PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    main(os.path.abspath(args.executable), args.capture_dir)
    run_installation_detail(os.path.abspath(args.executable))
    with open(args.executable, "rb") as binary:
        print("STUDIO_BINARY_SHA256=" + hashlib.sha256(binary.read()).hexdigest(), flush=True)
    run_navigation_consistency(os.path.abspath(args.executable))
    run_declared_report(os.path.abspath(args.executable), args.capture_dir)
