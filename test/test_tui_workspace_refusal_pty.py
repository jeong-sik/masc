"""Retained Repository and Sandbox rows refuse writes while identity is unconfirmed.

The terminal drives the actual key handlers and records every HTTP mutation;
the valid editor stub prevents missing editor configuration from hiding a POST.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile

import tui_keyboard_harness as h
from tui_keyboard_repositories import (
    REPOSITORIES_PATH,
    repositories_fixture,
    repository_declaration_editor_script,
)


class WorkspaceHealth:
    def __init__(self):
        self.base = ""
        self.ready = True

    def prepare(self, base):
        self.base = str(Path(base).resolve())

    def read(self):
        _, payload = h.fleet_safety_fixture()
        payload["paths"] = {
            "effective_base_path": self.base,
            "effective_masc_root": str(Path(self.base, ".masc")),
        }
        payload["startup"] = {"state_ready": self.ready}
        # Raw replies preserve the fixture's identity instead of the harness
        # replacing tuple response paths with its default workspace.
        return h.RawHttpResponse(
            200, json.dumps(payload).encode(), content_type="application/json"
        )

    def install(self, fixtures):
        fixtures["/health"] = self.read
        fixtures["/health?full=1"] = self.read

    def refuse(self, process, fd, output):
        self.ready = False
        h.send_and_wait(process, fd, output, b"r", b"[workspace unconfirmed]")


def retained_rows_refuse_writes(executable, surface):
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[REPOSITORIES_PATH] = repositories_fixture()
    health = WorkspaceHealth()
    health.install(fixtures)
    requests = []

    def interact(process, fd, _slave, output, _base):
        if surface == "Repository":
            h.palette_go(process, fd, output, b"go Workspace", b"MASC Workspace")
            h.wait_for_output(process, fd, output, b"workspace/masc", start=0, timeout=3.0)
        else:
            h.palette_go(process, fd, output, b"go Keepers", b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", "▸Info".encode())
            h.send_and_wait(process, fd, output, b"]", "▸Items".encode())
            h.send_and_wait(process, fd, output, b"]", "▸Sandbox".encode())
        health.refuse(process, fd, output)
        keys = (b"a",) if surface == "Repository" else (b"d", b"m", b"s")
        h.send_and_wait(process, fd, output, keys[0], b"Workspace identity is unconfirmed")
        for key in keys[1:]:
            os.write(fd, key)
        h.drain_until_quiet(process, fd, output)
        assert_no_writes()
        assert not editor_marker.exists(), "unconfirmed Repository action opened the editor"
        os.write(fd, b"q")

    def assert_no_writes():
        writes = [(path, body) for path, body in requests
                  if path == REPOSITORIES_PATH or path == "/api/v1/keepers/alpha/config"]
        assert not writes, ("retained rows dispatched while identity was unconfirmed", writes)

    # If the Repository admission check regresses, the editor returns a valid
    # declaration, so an absent editor cannot accidentally hide the POST.
    with tempfile.TemporaryDirectory(prefix="tui-refused-editor-") as editor_dir, \
            repository_declaration_editor_script() as editor:
        editor_marker = Path(editor_dir, "opened")
        script = Path(editor)
        script.write_text(script.read_text().replace(
            "#!/bin/sh\n", '#!/bin/sh\nprintf opened > "$MASC_TUI_REFUSAL_EDITOR_MARKER"\n', 1
        ))
        h.run_terminal_scenario(
            executable, description=f"Retained {surface} rows refuse unconfirmed writes",
            interact=interact, prepare_workspace=health.prepare,
            http_fixtures=fixtures, http_requests=requests, terminal_cols=160,
            extra_env={"EDITOR": editor, "MASC_TUI_REFUSAL_EDITOR_MARKER": str(editor_marker)},
        )
        assert not editor_marker.exists(), "unconfirmed Repository action opened the editor"
    assert_no_writes()


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    for surface in ("Repository", "Sandbox"):
        retained_rows_refuse_writes(executable, surface)
    print("Workspace refusal PTY: PASS (2 scenarios)", flush=True)
