"""A workspace change withdraws chat observations and preserves unsent input.

The running TUI uses an isolated loopback fixture. A starts as its matching
local workspace; B names the same Keeper on a different workspace. This is
synthetic HTTP/PTY evidence, not a live server or a remote-chat permission.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import threading

import test_tui_keyboard_input as h


# scripts/ci/run-edited-tests.sh selects this runnable alias when a changed
# source path occurs as a quoted literal here; it reads these outside Python.
SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_loader.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_keeper_selection.ml",
    "bin/masc_tui_render_chat.ml",
)

ROSTER_PATH = "/api/v1/gate/keepers?detailed=true"
HISTORY_PATH = "/api/v1/keepers/alpha/chat/history"
MEMORY_PATH = "/api/v1/keepers/alpha/memory-journal?limit=20"
BEFORE = b"workspace-a-visible-history"
LATE = b"workspace-a-late-history-must-not-return"
RECOVERED = b"workspace-a-current-history-after-return"
DRAFT = b"unsent-draft-owned-by-workspace-a"
WAIT_SECONDS = 8.0  # Fixture failure deadline, not a product refresh policy.


def screen(output: bytearray) -> bytes:
    end = output.rfind(h.FRAME_END)
    return h.screen_text(bytes(output[: end + len(h.FRAME_END)])) if end >= 0 else b""


def history_row(marker: bytes, stamp: float) -> h.HttpResponse:
    return 200, [{"id": marker.decode(), "role": "assistant",
                  "content": marker.decode(), "ts": stamp}]


class WorkspaceWire:
    def __init__(self, roster):
        self.lock = threading.Lock()
        self.local_base: str | None = None
        self.remote_base: str | None = None
        self.phase = "a"
        self.roster_template = roster
        self.hold_next = False
        self.held_started = threading.Event()
        self.release_held = threading.Event()
        self.held_returned = threading.Event()
        self.late_memory_requested = threading.Event()
        self.events: list[dict[str, object]] = []

    def prepare(self, base: str) -> None:
        with self.lock:
            self.local_base = str(Path(base).resolve())
            self.remote_base = str(Path(base, "different-server-workspace").resolve())

    def publish(self, phase: str) -> None:
        assert phase in ("a", "b", "b-after-late", "a-returned")
        with self.lock:
            self.phase = phase
            self.events.append({"event": "publish", "phase": phase})

    def arm_history(self) -> None:
        with self.lock:
            assert self.phase == "a" and not self.held_started.is_set()
            self.hold_next = True

    def health(self):
        with self.lock:
            phase = self.phase
            base = self.remote_base if phase.startswith("b") else self.local_base
            assert base is not None
            self.events.append({"event": "health", "phase": phase, "base_path": base})
        _, payload = h.fleet_safety_fixture()
        payload["paths"] = {"effective_base_path": base,
                            "effective_masc_root": str(Path(base, ".masc"))}
        # A tuple health response is rewritten to the harness workspace.
        # Raw bytes preserve the authority this scenario deliberately chose.
        return h.RawHttpResponse(200, json.dumps(payload).encode(),
                                 content_type="application/json")

    def roster(self):
        with self.lock:
            phase = self.phase
            self.events.append({"event": "roster", "phase": phase})
        payload = copy.deepcopy(self.roster_template)
        runtime = {"a": "a.current", "b": "b.current",
                   "b-after-late": "b.settled", "a-returned": "a.returned"}[phase]
        for row in payload["keepers"]:
            if row["name"] == "alpha":
                row["runtime_id"] = runtime
                row["meta"]["trace_id"] = "trace-alpha-" + phase
        return 200, payload

    def history(self):
        with self.lock:
            phase = self.phase
            held = self.hold_next and phase == "a"
            if held:
                self.hold_next = False
            self.events.append({"event": "history", "phase": phase, "held": held})
        if held:
            self.held_started.set()
            if not self.release_held.wait(timeout=30.0):
                return 504, {"error": "workspace history fixture gate timed out"}
            self.held_returned.set()
            return history_row(LATE, 1787348501.0)
        if phase == "a":
            return history_row(BEFORE, 1787348500.0)
        if phase == "a-returned":
            return history_row(RECOVERED, 1787348502.0)
        return 503, {"error": "B history must not inherit A's conversation"}

    def memory(self):
        with self.lock:
            phase = self.phase
            self.events.append({"event": "memory", "phase": phase})
        # The production history loader reads memory only after the held
        # history GET has completed. This observes client progress, not just
        # a fixture thread deciding to return its response.
        if phase.startswith("b") and self.held_returned.is_set():
            self.late_memory_requested.set()
        return 200, {"keeper": "alpha", "entries": []}


def run(binary: str, captures: Path | None) -> None:
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    fixtures[ROSTER_PATH] = wire.roster
    fixtures[HISTORY_PATH] = wire.history
    fixtures[MEMORY_PATH] = wire.memory
    fixtures["/health"] = wire.health
    fixtures["/health?full=1"] = wire.health
    posts: h.HttpRequests = []

    def capture(output, name):
        visible = screen(output)
        if captures is not None:
            (captures / (name + ".txt")).write_bytes(visible)
            (captures / (name + ".pty")).write_bytes(output)
        print("WORKSPACE_HISTORY_FRAME " + name + "\n" + visible.decode(errors="replace"), flush=True)

    def interact(process, fd, _slave, output, local_base):
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), f"{label}: {screen(output)!r}"

        try:
            assert str(Path(local_base).resolve()) == wire.local_base
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ alpha ▸ chat".encode())
            await_screen(lambda text: BEFORE in text, "A history was not displayed")
            h.send_and_wait(process, fd, output, DRAFT, h.composer_showing(DRAFT))
            capture(output, "a-history-and-draft")

            wire.arm_history()
            assert h.wait_for_fixture_event(process, fd, output, wire.held_started,
                timeout=WAIT_SECONDS), "the next automatic A history read did not start"
            wire.publish("b")
            await_screen(lambda text: b"MISMATCH local " in text and b"b.current" in text
                and b"MASC Keepers" in text and "▸ chat".encode() not in text,
                "B authority did not withdraw the old chat surface")
            assert BEFORE not in screen(output) and DRAFT not in screen(output)
            capture(output, "b-with-history-held")
            after_b = len(output)

            wire.release_held.set()
            assert h.wait_for_fixture_event(process, fd, output, wire.late_memory_requested,
                timeout=WAIT_SECONDS), "the TUI did not finish reading the released A history"
            wire.publish("b-after-late")
            await_screen(lambda text: b"b.settled" in text and b"MISMATCH local " in text,
                         "fresh B roster after the late response was not applied")
            h.resize_and_wait(process, fd, output, rows=35, columns=120,
                             needle=b"b.settled", controls=(h.FULL_REDRAW,))
            assert BEFORE not in screen(output) and LATE not in screen(output)
            assert DRAFT not in screen(output), "A's input was relabelled as a remote draft"
            capture(output, "b-after-late-response")

            # Return to the original matching workspace before asking to
            # compose. The test never opens or authorizes remote chat.
            wire.publish("a-returned")
            await_screen(lambda text: b"a.returned" in text and b"MISMATCH" not in text,
                         "the original workspace did not become authoritative again")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ alpha ▸ chat".encode())
            await_screen(lambda text: RECOVERED in text and DRAFT in text,
                         "returning to A did not restore the unsent draft and fresh history")
            assert BEFORE not in screen(output) and LATE not in screen(output)
            assert LATE not in h.CSI_RE.sub(b"", bytes(output[after_b:])), \
                "the released A response reappeared after the workspace boundary"
            capture(output, "a-restored-draft-current-history")
            assert not [path for path, _ in posts if path.startswith("/api/v1/keepers/")], \
                "preserving an unsent draft submitted Keeper work"
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            wire.release_held.set()
            if captures is not None:
                (captures / "complete.pty").write_bytes(output)
                with wire.lock:
                    events = list(wire.events)
                (captures / "requests.json").write_text(json.dumps({
                    "get_events": events,
                    "posts": [{"path": path, "body": json.loads(body)} for path, body in posts],
                }, indent=2) + "\n")

    h.run_terminal_scenario(binary,
        description="workspace change withdraws held chat history and retains its unsent draft",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        http_requests=posts, refresh=0.5, terminal_rows=34, terminal_cols=120)


if __name__ == "__main__":
    binary = str(Path(sys.argv[1]).resolve())
    artifact_root = os.environ.get("RUNNER_TEMP")
    captures = Path(artifact_root, "tui-remote-workspace-history") if artifact_root else None
    if captures is not None:
        captures.mkdir(parents=True, exist_ok=True)
        (captures / "manifest.json").write_text(json.dumps({
            "scope": "synthetic HTTP workspace A/B/A through the real TUI PTY; no live server",
            "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
            "scenario_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        }, indent=2) + "\n")
    run(binary, captures)
    print("remote workspace history: PASS (held response withdrawal and unsent draft retention)")
