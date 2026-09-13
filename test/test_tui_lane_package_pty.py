"""Real TUI/editor/HTTP interaction against controlled declaration responses.

The native owner tests cover filesystem semantics. This suite proves terminal
keys, delayed responses, draft retention and exact requests, without workers.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import threading

import test_tui_keyboard_input as terminal


def main(executable: str) -> None:
    requests: terminal.HttpRequests = []
    state: dict = {"directory": "", "document": None, "delay": False}
    posted = threading.Event()
    release = threading.Event()
    finished = threading.Event()
    fixtures = terminal.overview_event_http_fixtures()

    def document(name: str, source: str) -> dict:
        return {"file_name": name, "source_path": str(Path(state["directory"], name)),
                "source_text": source, "source_revision": hashlib.sha256(source.encode()).hexdigest(),
                "desired_revision": "desired-1", "validation": {"valid": True, "messages": []}}

    def inspect() -> tuple[int, dict]:
        doc = state["document"]
        return 200, {"instances": [], "rows": [], "coverage": [], "configuration": {
            "directory": state["directory"], "complete": True, "issues": [],
            "declarations": [] if doc is None else [{"id": "terminal-layer", "source_path": doc["source_path"],
                "desired_revision": "desired-1", "applied_revision": None, "instance_id": None}]}}

    def declaration(body: bytes) -> tuple[int, dict]:
        if not body:
            return 200, state["document"]
        request = json.loads(body)
        if state["delay"]:
            posted.set()
            if not release.wait(10):
                raise AssertionError("fixture save was never released")
        old = state["document"]
        if old is not None and (request["mode"] == "create" or request["expected_source_revision"] != old["source_revision"]):
            return 409, {"code": "revision_conflict", "error": "Current TOML changed", "current": old}
        if request["source_text"] == "id = [":
            return 400, {"code": "invalid_declaration", "error": "Malformed candidate", "current": old}
        state["document"] = document(request["file_name"], request["source_text"])
        if posted.is_set():
            finished.set()
        return 200, {"document": state["document"], "write": {"state": "created" if old is None else "saved",
                    "durability": "durable", "detail": None}, "application": "pending_reconciliation"}

    action_request = {"instance_id": "fixture-worker", "expected_incarnation": "fixture-worker",
                      "request_id": "fixture-request", "action": {"value": 1}}
    action_input = {"context": {"instance_id": "fixture-worker", "incarnation": "fixture-worker"},
                    "request_id": "fixture-request", "action": {"value": 1}}
    action_digest = hashlib.sha256(json.dumps(action_input, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def action(body: bytes) -> tuple[int, dict]:
        if body and json.loads(body) != action_request:
            raise AssertionError("TUI changed action request identity or arguments")
        return 200, {"instance_id": "fixture-worker", "incarnation": "fixture-worker",
                     "request_id": "fixture-request", "requester": "fixture-operator",
                     "executor": None if body else "fixture-executor", "input_sha256": action_digest,
                     "action": {"value": 1}, "state": "queued" if body else "confirmed",
                     "result": None if body else {"value": 1}, "detail": None}

    fixtures["/api/v1/lane-addons/actions"] = terminal.RequestHttpResponse(action)
    fixtures["/api/v1/lane-addons"] = inspect
    fixtures["/api/v1/lane-addons/declaration"] = terminal.RequestHttpResponse(declaration)

    with tempfile.TemporaryDirectory(prefix="lane-tui-editor-") as scratch:
        edit_text = Path(scratch, "next.toml")
        editor = Path(scratch, "editor.py")
        editor.write_text("import pathlib,sys\npathlib.Path(sys.argv[2]).write_bytes(pathlib.Path(sys.argv[1]).read_bytes())\n")
        source = 'id="terminal-layer"\nrun_id="world"\nmanifest_path="../lane.toml"\n[binding]\nsources=[]\n'
        edit_text.write_text(source)

        def prepare(base_path: str) -> None:
            state["directory"] = str(Path(base_path, ".masc/config/lane-addons"))

        def interact(process, master_fd, _slave_fd, output, _base_path):
            def key(value: bytes, needle: bytes):
                return terminal.send_and_wait(process, master_fd, output, value, needle)

            key(b":go lanes\r", b"MASC Lanes")
            key(b"A", b"MASC Lane Add-ons")
            key(b"\t", b"No instances.")
            key(b"\t", b"No observations.")
            key(b"\t", b"No installations.")
            key(b"q", b"MASC Lanes")
            key(b"\x1b", b"MASC Overview")
            key(b":go lane add-ons\r", b"MASC Lane Add-ons")
            key(b"n", b"New TOML filename:")
            key(b"terminal.toml\r", b"Draft edited; s saves")
            if requests:
                unexpected = [(path, body) for path, body in requests if path.startswith("/api/v1/lane-addons")]
                if unexpected:
                    raise AssertionError("opening a TOML draft wrote or attached a worker")
            key(b"s", b"Created")
            if state["document"]["source_text"] != source:
                raise AssertionError("TUI did not send exact editor bytes")

            # A server-side writer changed the file after our base was read.
            state["document"] = document("terminal.toml", "# externally changed\n" + source)
            edit_text.write_text("# operator text\n" + source)
            key(b"E", b"Draft edited; s saves")
            key(b"s", b"Current TOML changed")
            key(b"u", b"Current revision selected; draft preserved")
            key(b"s", b"Saved")
            if state["document"]["source_text"] != "# operator text\n" + source:
                raise AssertionError("rebase discarded the draft")

            edit_text.write_text("id = [")
            key(b"E", b"Draft edited; s saves")
            key(b"s", b"Malformed candidate")
            # Leaving/reopening keeps the invalid draft, not just the old file.
            key(b"q", b"MASC Overview")
            reopened = key(b":go lane add-ons\r", b"TOML draft terminal.toml")
            if b"id = [" not in terminal.CSI_RE.sub(b"", reopened):
                raise AssertionError("closing the pane discarded rejected TOML")

            # Save A can complete while the operator starts draft B. Its response
            # must update A without selecting A or losing B.
            edit_text.write_text("# final A\n" + source)
            key(b"E", b"Draft edited; s saves")
            state["delay"] = True
            posted.clear()
            release.clear()
            os.write(master_fd, b"s")
            if not posted.wait(5):
                raise AssertionError("save request did not reach fixture")
            key(b"n", b"New TOML filename:")
            edit_text.write_text("# second draft retained")
            key(b"second.toml\r", b"TOML draft second.toml")
            key(b"q", b"MASC Overview")
            key(b":go lane add-ons\r", b"TOML draft second.toml")
            terminal.read_available(master_fd, output)
            after_release = len(output)
            release.set()
            if not terminal.wait_for_fixture_event(process, master_fd, output, finished, timeout=5):
                raise AssertionError("delayed save did not finish")
            terminal.wait_for_output(process, master_fd, output, b"Retained server observations",
                                     start=after_release, timeout=5)
            state["delay"] = False
            # Inspect leaves the selected draft unchanged, so an incremental
            # frame need not print its title again. Join the new request and
            # its completion, then inspect B in a freshly opened pane below.
            refreshed = terminal.GatedHttpResponse(inspect())
            fixtures["/api/v1/lane-addons"] = refreshed
            key(b"r", b"Request pending")
            if not terminal.wait_for_fixture_event(process, master_fd, output, refreshed.requested, timeout=5):
                raise AssertionError("refresh request did not reach fixture")
            terminal.release_and_wait_for_frame(process, master_fd, output, refreshed,
                                                b"Retained server observations")
            if not refreshed.completed.is_set():
                raise AssertionError("refresh fixture did not complete")
            fixtures["/api/v1/lane-addons"] = inspect
            # Close the whole pane, revisit, then return to the regular TUI.
            key(b"q", b"MASC Overview")
            reopened = key(b":go lane add-ons\r", b"TOML draft second.toml")
            if b"# second draft retained" not in terminal.CSI_RE.sub(b"", reopened):
                raise AssertionError("late save or refresh discarded the second draft")
            key(b"\x1b", b"TOML installations")
            key(b":act " + json.dumps(action_request).encode() + b"\r", b"state queued")
            key(b"t", b"state confirmed")
            key(b"q", b"MASC Overview")
            os.write(master_fd, b"q")
            deadline = terminal.time.monotonic() + 3
            while len([path for path, _ in requests if path == "/api/v1/lane-addons/declaration"]) < 5:
                terminal.read_available(master_fd, output)
                if terminal.time.monotonic() >= deadline:
                    raise AssertionError("fifth explicit save was not captured")
                terminal.select.select([master_fd], [], [], 0.01)
            lane_requests = [(path, json.loads(body)) for path, body in requests
                             if path.startswith("/api/v1/lane-addons")]
            if any(path.endswith("/attach") for path, _ in lane_requests):
                raise AssertionError("TOML creation used manual attach")
            if any(body.get("file_name") == "second.toml" for _, body in lane_requests):
                raise AssertionError("starting a draft implicitly saved it")
            saves = [body for path, body in lane_requests if path.endswith("/declaration")]
            actions = [body for path, body in lane_requests if path.endswith("/actions")]
            if len(saves) != 5 or actions != [action_request]:
                raise AssertionError(f"expected five explicit saves and one action; got {lane_requests}")

        terminal.run_terminal_scenario(executable, description="Lane TOML package terminal",
            interact=interact, http_fixtures=fixtures, http_requests=requests,
            prepare_workspace=prepare, extra_env={"EDITOR": " ".join(map(shlex.quote, [sys.executable, str(editor), str(edit_text)]))})
    print("Lane TOML terminal create/conflict/draft/switch scenario: PASS")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_lane_package_pty.py <CI-built masc-tui>")
    main(os.path.abspath(sys.argv[1]))
