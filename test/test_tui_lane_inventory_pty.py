"""Common Lane navigation against explicit HTTP fixtures.

--check-fixtures only checks authored JSON and fixture relationships. The PTY
scenarios require a separately built native binary and are not run by that mode.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import shlex
import tempfile
import threading
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import tui_keyboard_harness as terminal
import tui_keyboard_keepers as lanes

DIRECTORY = "/fixture/lane-addons"
BROKEN_PATH = DIRECTORY + "/broken.toml"
MANUAL_ID = "manual-two"
MANUAL_INCARNATION = "manual-incarnation-two"
BROWSER_READ = "/api/v1/dashboard/browser-lane/read"
LIVE_PATH = "/api/v1/lane-addons/live"


def instance(instance_id=MANUAL_ID, *, managed=False):
    return {
        "instance_id": instance_id,
        "incarnation": MANUAL_INCARNATION if instance_id == MANUAL_ID else "inc-" + instance_id,
        "run_id": "fixture-world", "package_id": "observer", "title": "Manual observer",
        "package_revision": "package-1", "presence": "retained" if not managed else "live",
        "phase": {"kind": "failed", "message": "cleanup unconfirmed"} if not managed else {"kind": "observing"},
        "applied_revision": "old-valid-revision" if managed else None,
    }


def inventory_response(*, owner_present=True):
    declared = []
    # More rows than either 60x24 or 80x24 can show: End/search/press must share
    # the actual viewport and stable row identities, not old fixed y offsets.
    for index in range(18):
        name = "broken" if index == 0 else f"package-{index:02d}"
        path = DIRECTORY + "/" + name + ".toml"
        declaration = {"kind": "invalid", "messages": ["unterminated fixture binding"]} if index == 0 else {
            "kind": "valid", "installation_id": name, "run_id": "fixture-world",
            "package_id": "observer", "title": name, "desired_revision": "desired-1",
        }
        workers = [instance("broken-worker", managed=True)] if index == 0 else []
        if not owner_present:
            for worker in workers:
                worker["presence"] = "retained"
        declared.append({
            "id": "declaration/" + path, "label": name + ".toml",
            "purpose": "Package declaration and its owned observation workers.",
            "selection": {"kind": "declaration", "source_path": path},
            "state": {"kind": "package", "declaration": declaration,
                      "instances": workers},
        })
    worker = instance()
    declared.append({
        "id": "instance/" + MANUAL_ID, "label": worker["title"],
        "purpose": "Manual package attachment; no declaration file.",
        "selection": {"kind": "manual_instance", "instance_id": MANUAL_ID,
                      "incarnation": MANUAL_INCARNATION},
        "state": {"kind": "package", "declaration": None, "instances": [worker]},
    })
    return lanes.lane_inventory_response(package_rows=declared, package_read={
        "directory": DIRECTORY, "complete": False, "owner_present": owner_present,
        "issues": [{"source_path": BROKEN_PATH, "message": "unterminated fixture binding"}],
    })


def addon_snapshot():
    def addon_row(item):
        return {
            "instance_id": item["instance_id"], "incarnation": item["incarnation"],
            "run_id": item["run_id"], "addon_id": item["package_id"],
            "title": item["title"], "revision": item["package_revision"],
            "runtime_presence": item["presence"], "phase": item["phase"],
            "observation_seq": 0, "rows_count": 0, "configuration": None,
            "action_schema": None, "binding": {"sources": []},
            "package": {"outputs": {}, "skills_directory": None, "binding_schema": None,
                        "presentation": {"description": None, "readings": []}},
        }
    other = instance("other-worker")
    other["title"] = "Wrong first worker"
    return {
        "instances": [addon_row(other), addon_row(instance())],
        "rows": [], "coverage": [], "configuration": {
            "directory": DIRECTORY, "complete": True, "declarations": [], "issues": [],
        },
    }


def declaration_document():
    return {
        "file_name": "broken.toml", "source_path": BROKEN_PATH,
        "source_text": 'id = "broken"\n[binding\n', "source_revision": "broken-source",
        "desired_revision": None,
        "validation": {"valid": False, "messages": ["unterminated fixture binding"]},
    }


def settled_screen(process, fd, output):
    terminal.drain_until_quiet(process, fd, output)
    return terminal.screen_text(bytes(output))


def prose(screen):
    # Ignore frame borders and display wrapping, not missing words.
    return " ".join(line.strip(" │") for line in screen.decode().splitlines()).encode()


def select(process, fd, output, identity, visible_label):
    terminal.send_and_wait(process, fd, output, b"/" + identity.encode(),
                           re.compile(rb"\x1b\[7m[^\x1b\n]*" + re.escape(visible_label)))
    terminal.send_and_wait(process, fd, output, b"\x1b", b"j/k:move")


def run_inventory(executable, columns):
    fixtures = terminal.keeper_runtime_http_fixtures()
    inventory_reads = []
    addon_reads = []

    def read_inventory(path, *, owner_present=True):
        inventory_reads.append(path)
        return inventory_response(owner_present=owner_present)

    def read_addons(path):
        addon_reads.append(path)
        return 200, addon_snapshot()

    fixtures[lanes.LANE_INVENTORY_PATH] = terminal.PathHttpResponse(read_inventory)
    fixtures["/api/v1/lane-addons"] = terminal.PathHttpResponse(read_addons)
    requests = []

    def interact(process, fd, _slave, output, _base):
        # Remember a real Keeper before entering System Lanes: its global i
        # composer binding must not intercept inventory diagnostics.
        terminal.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
        terminal.select_keeper_row(process, fd, output, b"alpha")
        terminal.palette_go(process, fd, output, b"go lanes", b"All lanes")
        terminal.wait_for_output(process, fd, output, b"1 inventory issues", start=0, timeout=5)
        terminal.send_and_wait(process, fd, output, b"\x1b[F",
                               re.compile(rb"\x1b\[7m[^\x1b\n]*Manual observer"))
        screen = settled_screen(process, fd, output)
        if b"Manual observer" not in screen:
            raise AssertionError(f"End left selection outside the {columns}-column viewport: {screen!r}")
        terminal.send_and_wait(process, fd, output, b"d", b"manual attachment")
        os.write(fd, b"\x1b[F")
        # End can be a no-op when this reading already fits; inspect the
        # current screen instead of waiting for a nonexistent repaint.
        screen = settled_screen(process, fd, output)
        if b"retained failed: cleanup unconfirmed" not in prose(screen) or MANUAL_INCARNATION.encode() not in screen:
            raise AssertionError(f"retained worker was hidden or called off: {screen!r}")
        terminal.send_and_wait(process, fd, output, b"\x1b", b"All lanes")
        select(process, fd, output, "broken.toml", b"broken.toml")
        terminal.send_and_wait(process, fd, output, b"d", b"declaration invalid")
        screen = settled_screen(process, fd, output)
        if b"live observing" not in screen:
            raise AssertionError(f"invalid TOML concealed the older live worker: {screen!r}")
        os.write(fd, b"\x1b[F")
        if b"Applied declaration revision: old-valid-revision" not in settled_screen(process, fd, output):
            raise AssertionError("the full reading lost the live worker's applied revision")
        terminal.send_and_wait(process, fd, output, b"\x1b", b"All lanes")
        # Move away while preserving a scrolled viewport, then derive the
        # actual package row from terminal cells. A press must select by id.
        terminal.send_and_wait(process, fd, output, b"j",
                               re.compile(rb"\x1b\[7m[^\x1b\n]*package-01"))
        settled_screen(process, fd, output)
        rows = terminal.screen_rows(bytes(output))
        y = terminal.screen_row_of(rows, b"broken.toml")
        if y < 0:
            raise AssertionError(f"scrolled package row disappeared before press: {rows!r}")
        press = b"\x1b[<0;5;%dM\x1b[<0;5;%dm" % (y, y)
        terminal.send_and_wait(process, fd, output, press,
                               re.compile(rb"\x1b\[7m[^\x1b\n]*broken.toml"))
        terminal.send_and_wait(process, fd, output, b"i", b"Inventory diagnostics")
        screen = settled_screen(process, fd, output)
        for needle in (b"incomplete", b"unterminated fixture binding"):
            if needle not in prose(screen):
                raise AssertionError(f"full inventory diagnosis lost {needle!r}: {screen!r}")
        terminal.send_and_wait(process, fd, output, b"\x1b", b"All lanes")
        fixtures[lanes.LANE_INVENTORY_PATH] = terminal.PathHttpResponse(
            lambda path: read_inventory(path, owner_present=False))
        terminal.send_and_wait(process, fd, output, b"r", b"owner has not been observed")
        terminal.send_and_wait(process, fd, output, b"i", b"Inventory diagnostics")
        if b"owner has not been observed" not in prose(settled_screen(process, fd, output)):
            raise AssertionError("owner absence was hidden or reported as disabled")
        if addon_reads:
            raise AssertionError("package discovery depended on opening Add-ons")
        if not inventory_reads:
            raise AssertionError("common inventory endpoint was never read")
        print(f"LANE_INVENTORY_PTY width={columns}: End/search/ID press/d/i (synthetic HTTP)")
        terminal.send_and_wait(process, fd, output, b"\x1b", b"All lanes")
        os.write(fd, b"q")

    terminal.run_terminal_scenario(executable, description=f"common inventory at {columns} columns",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        terminal_cols=columns, terminal_rows=24, workspace="inventory")


def run_destinations(executable):
    fixtures = terminal.overview_event_http_fixtures()
    fixtures[lanes.LANE_INVENTORY_PATH] = inventory_response()
    fixtures["/api/v1/lane-addons"] = (200, addon_snapshot())
    fixtures["/api/v1/dashboard/browser-lane/clients"] = (200, {"ok": True, "data": {
        "clients": [{"clientId": "fixture-client", "browser": "firefox"}],
    }})
    browser_reads = []
    slice_reads = []
    exact_reads = []
    machine_reads = []
    declaration_reads = []

    def exact_read(path):
        exact_reads.append(path)
        return lanes.verifier_lane_runs_response()

    def declaration_read(path):
        query = parse_qs(urlsplit(path).query)
        if query != {"source_path": [BROKEN_PATH]}:
            raise AssertionError(f"declaration read changed the source: {query!r}")
        declaration_reads.append(path)
        return 200, declaration_document()

    fixtures[lanes.lane_runs_path("verifier_exact")] = terminal.PathHttpResponse(exact_read)
    fixtures["/api/v1/lane-addons/declaration"] = terminal.PathHttpResponse(declaration_read)

    def retained_slice(path):
        query = parse_qs(urlsplit(path).query)
        if query != {"run_id": ["fixture-world"]}:
            raise AssertionError(f"retained inventory selection changed the run: {query!r}")
        slice_reads.append(path)
        row = {
            "id": MANUAL_ID + "/" + MANUAL_INCARNATION + "/record-1",
            "lane_id": MANUAL_ID + "/records", "kind": "event",
            "title": "Retained selection proof", "observed_at": 1787557669.0,
            "subject_id": "fixture-world", "clock": None, "actor": None,
            "fields": {"selected_incarnation": MANUAL_INCARNATION},
            "evidence": [], "related_ids": [],
        }
        return 200, {"rows": [row], "coverage": [], "complete": True}

    fixtures["/api/v1/lane-addons/slice"] = terminal.PathHttpResponse(retained_slice)

    def browser_read(body):
        request = json.loads(body)
        browser_reads.append(request)
        text = "typed " + request["lane"]
        return 200, {"ok": True, "data": {
            "source": request["lane"], "clientId": request.get("clientId"), "elapsed_ms": 1.0,
            "tabs": [{"id": 2, "title": text, "url": "https://example.invalid/", "active": True}],
            "page": {"tabId": 2, "title": text, "url": "https://example.invalid/",
                     "text": text, "chars": len(text), "truncated": False},
        }}

    def machine_read(path):
        machine_reads.append(path)
        kind = parse_qs(urlsplit(path).query)["source_kind"][0]
        return 200, {"source_kind": kind, "state": "no_machine",
                     **({"activity": []} if kind == "dos_capture" else {})}

    fixtures[BROWSER_READ] = terminal.RequestHttpResponse(browser_read)
    fixtures[LIVE_PATH] = terminal.PathHttpResponse(machine_read)
    requests = []
    with tempfile.TemporaryDirectory(prefix="lane-inspect-editor-") as scratch:
        marker = Path(scratch, "editor-was-invoked")
        # Only a sentinel; Enter must never spawn the external editor. No
        # user editor or process is touched even if the product regresses.
        editor = Path(scratch, "editor.sh")
        editor.write_text("#!/bin/sh\ntouch " + shlex.quote(str(marker)) + "\n")
        editor.chmod(0o700)

        def interact(process, fd, _slave, output, _base):
            def open_inventory():
                terminal.palette_go(process, fd, output, b"go lanes", b"Lanes (31 lanes)")
                screen = settled_screen(process, fd, output)
                if b"All lanes" not in screen or b"1 inventory issues" not in screen:
                    raise AssertionError(f"inventory navigation lost its body: {screen!r}")

            open_inventory()
            select(process, fd, output, "exact/verifier_exact", b"Verifier")
            terminal.send_and_wait(process, fd, output, b"\r", b"task task-9")
            if not terminal.wait_for_fixture_state(process, fd, output,
                    lambda: lanes.lane_runs_path("verifier_exact") in exact_reads, timeout=5):
                raise AssertionError("the selected exact Lane was never read")
            # Go Lanes retains its sub-reading; use the run list's own back key.
            terminal.send_and_wait(process, fd, output, b"\x1b", b"All lanes")
            for lane, label in (("automation", b"Browser automation"), ("stagehand", b"Browser Stagehand"), ("live", b"Live browser")):
                open_inventory()
                select(process, fd, output, "browser/" + lane, label)
                terminal.send_and_wait(process, fd, output, b"\r", ("typed " + lane).encode())
                expected_client = "fixture-client" if lane == "live" else None
                if browser_reads[-1].get("lane") != lane or browser_reads[-1].get("clientId") != expected_client:
                    raise AssertionError(f"typed browser selection changed backend/client: {browser_reads!r}")
                terminal.send_and_wait(process, fd, output, b"\x1b", b"MASC")
            for machine in ("msx", "dos"):
                open_inventory()
                select(process, fd, output, "machine/" + machine, machine.upper().encode())
                terminal.read_available(fd, output)
                mark = len(output)
                os.write(fd, b"\r")
                terminal.wait_for_output(process, fd, output, b"no machine loaded", start=mark, timeout=5)
                if not terminal.wait_for_fixture_state(process, fd, output,
                        lambda: LIVE_PATH + "?source_kind=" + machine + "_capture" in machine_reads, timeout=5):
                    raise AssertionError(f"the selected {machine} live screen was never read")
                terminal.send_and_wait(process, fd, output, b"\x1b", b"All lanes")
            open_inventory()
            select(process, fd, output, "broken.toml", b"broken.toml")
            terminal.send_and_wait(process, fd, output, b"\r", b"TOML draft broken.toml")
            if not terminal.wait_for_fixture_state(process, fd, output,
                    lambda: any(urlsplit(path).path == "/api/v1/lane-addons/declaration"
                                and parse_qs(urlsplit(path).query) == {"source_path": [BROKEN_PATH]}
                                for path in declaration_reads), timeout=5):
                raise AssertionError("the selected declaration was never read")
            if marker.exists():
                raise AssertionError("Enter spawned the external editor instead of inspecting TOML")
            # Esc closes the document but leaves the Technical installation
            # view. Its title is unchanged and may not be repainted; wait for
            # the new body before q closes the Add-ons overlay.
            terminal.send_and_wait(process, fd, output, b"\x1b", b"Installation inventory unread")
            terminal.send_and_wait(process, fd, output, b"q", b"All lanes")
            select(process, fd, output, "instance/" + MANUAL_ID, b"Manual observer")
            terminal.send_and_wait(process, fd, output, b"\r", b"Manual observer")
            if not terminal.wait_for_fixture_state(process, fd, output,
                    lambda: "/api/v1/lane-addons/slice?run_id=fixture-world" in slice_reads, timeout=5):
                raise AssertionError("the selected retained worker history was never read")
            terminal.send_and_wait(process, fd, output, b"4", b"Retained selection proof")
            terminal.send_and_wait(process, fd, output, b"D", MANUAL_INCARNATION.encode())
            screen = settled_screen(process, fd, output)
            if MANUAL_ID.encode() not in screen or b"Wrong first worker" in screen:
                raise AssertionError(f"manual row opened a different worker: {screen!r}")
            prohibited = ("/attach", "/detach", "/observe", "/actions", "/load", "/press")
            mutations = [(p, b) for p, b in requests if p.endswith(prohibited) or
                         (p == "/api/v1/lane-addons/declaration" and b)]
            if mutations:
                raise AssertionError(f"inspection sent mutations: {mutations!r}")
            if not slice_reads:
                raise AssertionError("retained selection stopped after Inspect without reading history")
            # Leave Technical detail, then the worker, then the overlay.
            # Each wait names a changed body instead of its unchanged title.
            terminal.send_and_wait(process, fd, output, b"\x1b", b"1 Results")
            terminal.send_and_wait(process, fd, output, b"q", b"Retained history")
            terminal.send_and_wait(process, fd, output, b"q", b"All lanes")
            os.write(fd, b"q")

        terminal.run_terminal_scenario(executable, description="common Lane Enter destinations preserve identities",
            interact=interact, http_fixtures=fixtures, http_requests=requests,
            terminal_cols=100, terminal_rows=35, extra_env={"EDITOR": str(editor), "VISUAL": str(editor)})


def run_msx_live_recovery(executable):
    """One open MSX spectator recovers through live GET after a transient failure."""
    fixtures = terminal.keeper_runtime_http_fixtures()
    fixtures[lanes.LANE_INVENTORY_PATH] = inventory_response()
    recovered = threading.Event()
    reads = []
    requests = []

    def machine_read(path):
        query = parse_qs(urlsplit(path).query)
        if set(query) != {"source_kind"}:
            raise AssertionError(f"initial/recovery read carried an unobserved mark: {query!r}")
        reads.append(path)
        if not recovered.is_set():
            return 503, {"error": "fixture live read unavailable"}
        return 200, {"source_kind": query["source_kind"][0], "state": "no_machine"}

    fixtures[LIVE_PATH] = terminal.PathHttpResponse(machine_read)

    def interact(process, fd, _slave, output, _base):
        terminal.palette_go(process, fd, output, b"go lanes", b"All lanes")
        select(process, fd, output, "machine/msx", b"MSX")
        terminal.read_available(fd, output)
        start = len(output)
        os.write(fd, b"\r")
        # The spectator uses its own terminal renderer, not FRAME_END.
        terminal.wait_for_output(process, fd, output, b"fixture live read unavailable", start=start, timeout=5)
        terminal.read_available(fd, output)
        start = len(output)
        recovered.set()
        # No key closes/reopens or manually refreshes the spectator.
        terminal.wait_for_output(process, fd, output, b"no machine loaded", start=start, timeout=5)
        if len(reads) < 2:
            raise AssertionError("the open spectator recovered without another live read")
        mutations = [(path, body) for path, body in requests if path.startswith("/api/v1/msx/")]
        if mutations:
            raise AssertionError(f"live-read recovery mutated the machine: {mutations!r}")
        terminal.send_and_wait(process, fd, output, b"\x1b", b"All lanes")
        os.write(fd, b"q")

    terminal.run_terminal_scenario(executable,
        description="Open MSX inventory spectator retries transient live read without reopening",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        terminal_cols=120, terminal_rows=35)


def check_fixtures():
    status, payload = inventory_response()
    assert status == 200 and payload["schema"] == "masc.lane-inventory/v1"
    assert set(payload) == {"schema", "observed_at", "rows", "exact_snapshot", "package_read"}
    rows = payload["rows"]
    assert len(rows) == 31 and len({row["id"] for row in rows}) == len(rows)
    assert [row["selection"]["kind"] for row in rows[:12]].count("exact") == 7
    assert {row["id"] for row in rows[7:12]} == {
        "browser/live", "browser/automation", "browser/stagehand", "machine/msx", "machine/dos"}
    for row, exact in zip(rows[:7], payload["exact_snapshot"]["lanes"], strict=True):
        assert row["selection"]["lane_id"] == exact["lane_id"]
        config = row["state"]["configuration"]
        assert all(config[key] == exact[key] for key in config if key != "kind")
    broken = rows[12]
    assert broken["selection"]["source_path"] == declaration_document()["source_path"]
    assert broken["state"]["declaration"]["kind"] == "invalid"
    assert broken["state"]["instances"][0]["phase"]["kind"] == "observing"
    manual = rows[-1]
    item = addon_snapshot()["instances"][1]
    assert manual["selection"]["instance_id"] == item["instance_id"] == MANUAL_ID
    assert manual["selection"]["incarnation"] == item["incarnation"] == MANUAL_INCARNATION
    assert manual["state"]["instances"][0]["applied_revision"] is None
    assert payload["package_read"]["complete"] is False
    assert payload["package_read"]["owner_present"] is True
    absent = inventory_response(owner_present=False)[1]
    assert absent["package_read"]["owner_present"] is False
    assert all(item["presence"] == "retained" for row in absent["rows"]
               for item in row["state"].get("instances", []))
    # The helper embeds the captured old snapshot rather than consulting a
    # global/current fixture. This checks data provenance, not TUI scheduling.
    captured = copy.deepcopy(payload["exact_snapshot"])
    current = copy.deepcopy(captured)
    current["lanes"][0]["declared_slots"] = ["new-slot"]
    old_reply = lanes.lane_inventory_response(exact_snapshot=captured)[1]
    new_reply = lanes.lane_inventory_response(exact_snapshot=current)[1]
    assert old_reply["rows"][0]["state"]["configuration"]["declared_slots"] != new_reply["rows"][0]["state"]["configuration"]["declared_slots"]
    json.dumps(payload, allow_nan=False)
    print("Common Lane authored fixture wire checks: PASS; no native TUI/PTY executed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", nargs="?")
    parser.add_argument("--check-fixtures", action="store_true")
    args = parser.parse_args()
    if args.check_fixtures:
        check_fixtures()
    else:
        if args.executable is None:
            parser.error("a separately built TUI executable is required")
        executable = os.path.abspath(args.executable)
        for columns in (60, 80):
            run_inventory(executable, columns)
        run_destinations(executable)
        run_msx_live_recovery(executable)
        print("Common Lane inventory focused PTY scenarios: PASS (synthetic HTTP)")
