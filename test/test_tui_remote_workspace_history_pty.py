"""A workspace change withdraws chat observations and preserves unsent input.

The running TUI uses an isolated loopback fixture. A starts as its matching
local workspace; B names the same Keeper on a different workspace. This is
synthetic HTTP/PTY evidence, not a live server or a remote-chat permission.
"""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
import shlex
import tempfile
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
    "bin/masc_tui_render_prim.ml",
)

ROSTER_PATH = "/api/v1/gate/keepers?detailed=true"
HISTORY_PATH = "/api/v1/keepers/alpha/chat/history"
MEMORY_PATH = "/api/v1/keepers/alpha/memory-journal?limit=20"
BEFORE = b"workspace-a-visible-history"
LATE = b"workspace-a-late-history-must-not-return"
RECOVERED = b"workspace-a-current-history-after-return"
DRAFT = b"unsent-draft-owned-by-workspace-a"
WAIT_SECONDS = 8.0  # Fixture failure deadline, not a product refresh policy.
# Runtime identities are the response-generation barrier below. Keep the
# lifecycle/runtime column visible instead of waiting for a hidden cell.
TERMINAL_COLUMNS = h.KEEPER_RUNTIME_COLUMN_COLUMNS


def screen(output: bytearray) -> bytes:
    end = output.rfind(h.FRAME_END)
    return h.screen_text(bytes(output[: end + len(h.FRAME_END)])) if end >= 0 else b""


def history_row(marker: bytes, stamp: float) -> h.HttpResponse:
    return 200, [{"id": marker.decode(), "role": "assistant",
                  "content": marker.decode(), "ts": stamp}]


class WorkspaceWire:
    def __init__(self, roster, *, root_only=False):
        self.lock = threading.Lock()
        self.local_base: str | None = None
        self.remote_base: str | None = None
        self.phase = "a"
        self.root_only = root_only
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
            root = str(Path(base, ".masc"))
            if self.root_only:
                base = self.local_base
            self.events.append({"event": "health", "phase": phase, "base_path": base})
        _, payload = h.fleet_safety_fixture()
        payload["paths"] = {"effective_base_path": base,
                            "effective_masc_root": root}
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
    context = h.context_inspector_fixtures()
    context_path = "/api/v1/keepers/alpha/provider-input?turn_ref=trace-context%2342"
    held_context = h.GatedHttpResponse(context[context_path],
        subsequent_response=context[context_path], hold_seconds=30.0)
    fixtures["/api/v1/keepers/alpha/turn-records?limit=50"] = context[
        "/api/v1/keepers/alpha/turn-records?limit=50"]
    fixtures[context_path] = held_context
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
            h.resize_and_wait(process, fd, output,
                rows=34, columns=TERMINAL_COLUMNS, needle=b"MASC Dashboard",
                controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            assert str(Path(local_base).resolve()) == wire.local_base
            metadata_path = Path(local_base, ".masc", "keepers", "alpha.json")
            metadata_bytes = metadata_path.read_bytes()
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ alpha ▸ chat".encode())
            await_screen(lambda text: BEFORE in text, "A history was not displayed")
            h.send_and_wait(process, fd, output, DRAFT, h.composer_showing(DRAFT))
            capture(output, "a-history-and-draft")

            wire.arm_history()
            assert h.wait_for_fixture_event(process, fd, output, wire.held_started,
                timeout=WAIT_SECONDS), "the next automatic A history read did not start"
            h.send_and_wait(process, fd, output, b"\x18", b"MASC Context")
            assert h.wait_for_fixture_event(process, fd, output, held_context.requested,
                timeout=WAIT_SECONDS), "A exact-context read was not held"
            wire.publish("b")
            await_screen(lambda text: b"MISMATCH local " in text and b"b.current" in text
                and b"MASC Keepers" in text and "▸ chat".encode() not in text,
                "B authority did not withdraw the old chat surface")
            assert BEFORE not in screen(output) and DRAFT not in screen(output)
            assert b"MASC Context" not in screen(output), "A Context overlay survived B authority"
            capture(output, "b-with-history-held")
            after_b = len(output)

            wire.release_held.set()
            held_context.release.set()
            # Withdrawal cancels the chained read. A server thread returning
            # its old response does not prove a client callback was applied.
            wire.publish("b-after-late")
            await_screen(lambda text: b"b.settled" in text and b"MISMATCH local " in text,
                         "fresh B roster after the late response was not applied")
            h.resize_and_wait(process, fd, output, rows=35, columns=TERMINAL_COLUMNS,
                             needle=b"b.settled", controls=(h.FULL_REDRAW,))
            assert BEFORE not in screen(output) and LATE not in screen(output)
            assert DRAFT not in screen(output), "A's input was relabelled as a remote draft"
            with wire.lock:
                assert not [event for event in wire.events
                    if event["event"] == "memory" and str(event["phase"]).startswith("b")],                     "a withdrawn A history read continued into B's memory journal"
            refusal = b"Chat requires a matching workspace"
            for key in (b"m", b"i"):
                # A repeated refusal leaves identical footer cells, so the
                # incremental renderer need not emit those bytes again.
                # Require the previous notice to leave the current screen
                # before asking this entry path for its own visible refusal.
                if refusal in screen(output):
                    h.write_all(fd, output, b"\x1b")
                    await_screen(lambda text: refusal not in text,
                                 "previous chat refusal did not clear")
                h.send_and_wait(process, fd, output, key, refusal)
                assert "▸ chat".encode() not in screen(output)
            h.palette_go(process, fd, output, b"keeper alpha", b"Chat requires a matching workspace")
            with wire.lock:
                assert not [event for event in wire.events
                    if event["event"] in ("history", "memory")
                    and str(event["phase"]).startswith("b")],                     "a remote chat entry path read conversation data"
            capture(output, "b-after-late-response")

            # Return to the original matching workspace before asking to
            # compose. The test never opens or authorizes remote chat.
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", "▸Info".encode())
            # A failed local read after B must not preserve B's same-name
            # selectable row or combine its metadata with A lifecycle facts.
            metadata_path.write_text("{not-json", encoding="utf-8")
            wire.publish("a-returned")
            await_screen(lambda text: b"MISMATCH" not in text
                         and b"no Keeper selected" in text and b"keeper metadata read failed" in text,
                         "failed A metadata reload retained B's Keeper detail")
            metadata_path.write_bytes(metadata_bytes)
            os.write(fd, b"r")
            h.resize_and_wait(process, fd, output, rows=70, columns=TERMINAL_COLUMNS,
                             needle=b"Total Turns:", controls=(h.FULL_REDRAW,))
            await_screen(lambda text: b"Total Turns:" in text
                         and b"no Keeper selected" not in text,
                         "repaired A metadata was not reloaded")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
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
            h.send_and_wait(process, fd, output, b"\x18", b"MASC Context")
            await_screen(lambda text: b"50.0k" in text and b"200.0k" in text,
                         "returning to A did not load a fresh Context reading")
            assert held_context.subsequent_requested.is_set(), "A reused its withdrawn Context cache"
            capture(output, "a-fresh-context-after-return")
            h.send_and_wait(process, fd, output, b"\x1b", "▸ chat".encode())
            assert not [path for path, _ in posts if path.startswith("/api/v1/keepers/")], \
                "preserving an unsent draft submitted Keeper work"
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            if "metadata_path" in locals() and "metadata_bytes" in locals():
                metadata_path.write_bytes(metadata_bytes)
            wire.release_held.set()
            held_context.release.set()
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
        http_requests=posts, refresh=0.5, terminal_cols=TERMINAL_COLUMNS)


def scoped_roster_authority(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    template = fixtures[ROSTER_PATH][1]
    class ScopedWire(WorkspaceWire):
        def __init__(self):
            super().__init__(template)
            self.phase = "b"
            self.hold_roster = False
            self.roster_started = threading.Event()
            self.roster_release = threading.Event()
        def health(self):
            with self.lock:
                base = "/fixture-workspace-b" if self.phase == "b" else "/fixture-workspace-c"
            _, payload = h.fleet_safety_fixture()
            payload["paths"] = {"effective_base_path": base,
                                "effective_masc_root": str(Path(base, ".masc"))}
            return h.RawHttpResponse(200, json.dumps(payload).encode(), content_type="application/json")
        def roster(self):
            with self.lock:
                phase = self.phase
                held = self.hold_roster and phase == "b"
                if held:
                    self.hold_roster = False
            payload = copy.deepcopy(template)
            row = next(row for row in payload["keepers"] if row["name"] == "alpha")
            row["name"] = "b-only" if phase == "b" else "c-only"
            row["meta"]["name"] = row["name"]
            if held:
                self.roster_started.set()
                assert self.roster_release.wait(timeout=30), "scoped B roster was not released"
            return 200, payload
        def board(self):
            with self.lock:
                title = "workspace-b-board" if self.phase == "b" else "workspace-c-board"
            return 200, {"posts": [h.board_selection_post("scope", title, "authority fixture")]}
    wire = ScopedWire()
    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
                     "/health?full=1": wire.health,
                     "/api/v1/board?sort_by=hot": wire.board})
    def interact(process, fd, _slave, output, _base):
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), label
        try:
            # At 80 columns the Activity pane is not drawn. Board does not
            # need the roster, so entering Keepers dispatches a scoped GET.
            h.resize_and_wait(process, fd, output,
                rows=32, columns=80, needle=b"MASC Dashboard",
                controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            h.palette_go(process, fd, output, b"go Board", b"MASC Board")
            await_screen(lambda text: b"workspace-b-board" in text, "B Board read did not settle")
            with wire.lock:
                wire.hold_roster = True
            h.palette_go(process, fd, output, b"go Keepers", b"MASC Keepers")
            assert h.wait_for_fixture_event(process, fd, output, wire.roster_started,
                timeout=WAIT_SECONDS), "the scoped B roster was not held"
            h.palette_go(process, fd, output, b"go Board", b"MASC Board")
            wire.publish("b-after-late")
            h.resize_and_wait(process, fd, output, rows=32, columns=300,
                             needle=b"MASC Board", controls=(h.FULL_REDRAW,))
            os.write(fd, b"r")
            # While a scoped read is held the full revalidation still owns
            # /health. Its exact Base footer is the applied identity barrier;
            # the wider frame keeps both workspace paths visible.
            await_screen(lambda text: b"Base: /fixture-workspace-c" in text,
                         "full C identity reading did not become current")
            c_boundary = len(output)
            h.palette_go(process, fd, output, b"go Keepers", b"MASC Keepers")
            wire.roster_release.set()
            # Revalidate while scoped-inflight queued a full followup. Only
            # the stale scoped completion retires that flag and launches it.
            # Its C row is the client barrier after the B completion.
            await_screen(lambda text: b"c-only" in text, "C followup roster did not become selectable")
            assert b"b-only" not in h.CSI_RE.sub(b"", bytes(output[c_boundary:])),                 "the superseded B scoped roster was rendered under C authority"
            h.select_keeper_row(process, fd, output, b"c-only")
            os.write(fd, b"q")
        finally:
            wire.roster_release.set()
    h.run_terminal_scenario(binary,
        description="superseded scoped roster cannot replace a newer full workspace reading",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        refresh=30.0, terminal_cols=80)


def queued_workspace_inputs(binary: str, *, root_only=False) -> None:
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1], root_only=root_only)
    queued = b"retained-workspace-a-queued-payload"
    class HeldAdmission(h.AtomicChatFixture):
        def __init__(self):
            super().__init__(no_control_token=True)
            self.held_received = threading.Event()
            self.release_admission = threading.Event()
            self.held_once = False
            self.phases = []
        def stream(self, body):
            with wire.lock:
                self.phases.append(wire.phase)
            if not self.held_once:
                self.held_once = True
                self.held_received.set()
                assert self.release_admission.wait(timeout=30), "admission fixture was not released"
            return super().stream(body)
    admission = HeldAdmission()
    fixtures.update(admission.fixtures)
    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
                     "/health?full=1": wire.health, HISTORY_PATH: wire.history,
                     MEMORY_PATH: wire.memory})
    def interact(process, fd, _slave, output, _base):
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), label
        try:
            h.resize_and_wait(process, fd, output,
                rows=40, columns=TERMINAL_COLUMNS, needle=b"MASC Dashboard",
                controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ alpha ▸ chat".encode())
            await_screen(lambda text: BEFORE in text, "A history was not ready")
            h.send_and_wait(process, fd, output, b"first-workspace-a-request", h.composer_showing(b"first-workspace-a-request"))
            os.write(fd, b"\r")
            assert h.wait_for_fixture_event(process, fd, output, admission.held_received,
                timeout=WAIT_SECONDS), "first admission was not held"
            h.send_and_wait(process, fd, output, queued, h.composer_showing(queued))
            h.send_and_wait(process, fd, output, b"\r", b"Queue (1 waiting")
            wire.publish("b")
            await_screen(lambda text: b"b.current" in text and b"MISMATCH local " in text,
                         "B authority did not become visible")
            admission.release_admission.set()
            wire.publish("b-after-late")
            await_screen(lambda text: b"b.settled" in text, "fresh B receipt was not applied")
            assert admission.phases == ["a"], "late admission sent A's queued input to B"
            wire.publish("a-returned")
            await_screen(lambda text: b"a.returned" in text and b"MISMATCH" not in text,
                         "A authority was not restored")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ alpha ▸ chat".encode())
            await_screen(lambda text: b"Queue (1 waiting" in text and queued in text,
                         "the original queued input was not restored for A")
            assert admission.phases == ["a"], "returning automatically dispatched retained input"
            h.send_and_wait(process, fd, output, b"/queue resume", h.composer_showing(b"/queue resume"))
            h.send_and_wait(process, fd, output, b"\r", b"Server confirmed queue resume")
            h.wait_for_atomic_admissions(process, fd, output, admission, 2)
            assert admission.phases == ["a", "a-returned"], admission.phases
            assert admission.submitted[1]["message"] == queued.decode(), admission.submitted
            assert admission.submitted[1].get("admission_intent") is None
            h.escape_to_keeper_detail(process, fd, output, name=b"alpha")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            admission.release_admission.set()
            admission.release.set()
            admission.release_interrupt.set()
    h.run_terminal_scenario(binary,
        description=("MASC-root-only change" if root_only else "workspace change")
            + " suspends complete unsent inputs until explicit resume in A",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        refresh=0.5, terminal_cols=TERMINAL_COLUMNS)


def staged_payload_workspace_inputs(binary: str, *, root_only=False) -> None:
    """Actual /attach + /ref payloads survive A/B/A only for their original Keeper."""
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1], root_only=root_only)
    admission = h.AtomicChatFixture(no_control_token=True)
    fixtures.update(admission.fixtures)
    beta_submitted = []
    def beta_request(body):
        beta_submitted.append(json.loads(body))
        return 503, {"error": "synthetic beta admission refused"}
    def chat_request(body):
        return beta_request(body) if json.loads(body)["name"] == "beta" else admission.stream(body)
    fixtures["/api/v1/keepers/chat/stream"] = h.RequestHttpResponse(chat_request)
    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
                     "/health?full=1": wire.health, HISTORY_PATH: wire.history,
                     MEMORY_PATH: wire.memory})
    staged_text = b"workspace-a-alpha-staged-payload"
    reference = "https://fixture.invalid/workspace-a-alpha.png"
    image_data = []
    def prepare(base):
        wire.prepare(base)
        h.seed_image_workspace(base)
        image_data.append(base64.b64encode(Path(base, h.IMAGE_NAME).read_bytes()).decode())
    def interact(process, fd, _slave, output, base):
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), label
        try:
            h.resize_and_wait(process, fd, output,
                rows=40, columns=300, needle=b"MASC Dashboard",
                controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ alpha ▸ chat".encode())
            await_screen(lambda text: BEFORE in text, "A history was not ready")
            for command, receipt in ((f"/attach {Path(base, h.IMAGE_NAME)}".encode(), b"attached shot.png"),
                                     (f"/ref {reference}".encode(), b"reference(s)")):
                h.send_and_wait(process, fd, output, command, h.composer_showing(command))
                h.send_and_wait(process, fd, output, b"\r", receipt)
            h.send_and_wait(process, fd, output, staged_text, h.composer_showing(staged_text))
            wire.publish("b")
            await_screen(lambda text: b"b.current" in text and b"MASC Keepers" in text
                         and b"MISMATCH local " in text, "B withdrawal was not applied")
            assert staged_text not in screen(output)
            assert admission.submitted == [] and beta_submitted == []
            wire.publish("a-returned")
            await_screen(lambda text: b"a.returned" in text and b"MISMATCH" not in text,
                         "A authority was not restored")
            h.select_keeper_row(process, fd, output, b"beta")
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ beta ▸ chat".encode())
            assert staged_text not in screen(output), "alpha draft was restored for beta"
            h.send_and_wait(process, fd, output, b"beta-has-no-alpha-media", h.composer_showing(b"beta-has-no-alpha-media"))
            os.write(fd, b"\r")
            assert h.wait_for_fixture_state(process, fd, output, lambda: len(beta_submitted) == 1,
                timeout=WAIT_SECONDS), "beta request was not observed"
            assert beta_submitted[0].get("attachments", []) == [], beta_submitted
            assert not [block for block in beta_submitted[0].get("user_blocks", [])
                        if block.get("type") == "image"], beta_submitted
            h.escape_to_keeper_detail(process, fd, output, name=b"beta")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ alpha ▸ chat".encode())
            await_screen(lambda text: staged_text in text, "alpha draft was not restored")
            os.write(fd, b"\r")
            h.wait_for_atomic_admissions(process, fd, output, admission, 1)
            actual = admission.submitted[0]
            assert actual["message"] == staged_text.decode(), actual
            assert len(actual.get("attachments", [])) == 1, actual
            attached = actual["attachments"][0]
            assert attached["name"] == h.IMAGE_NAME and attached["data"] == image_data[0], attached
            images = [block for block in actual["user_blocks"] if block.get("type") == "image"]
            assert images == [{"type": "image", "attachment_id": attached["id"]},
                              {"type": "image", "url": reference}], actual
            h.escape_to_keeper_detail(process, fd, output, name=b"alpha")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            admission.release.set()
            admission.release_interrupt.set()
    h.run_terminal_scenario(binary,
        description=("MASC-root-only transition: " if root_only else "")
            + "staged image bytes and references retain exact workspace and Keeper ownership",
        interact=interact, prepare_workspace=prepare, http_fixtures=fixtures,
        refresh=0.5, terminal_cols=300)


def armed_schedule_and_runtime_workspace(binary: str) -> None:
    """Same schedule ID on B needs a fresh arm; the old runtime picker closes."""
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    fixtures.update(h.schedule_detail_http_fixtures())
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    schedule_template = fixtures[h.SCHEDULES_PATH][1]
    unknown_health = threading.Event()
    cancel_requests = []
    def schedules():
        with wire.lock:
            phase = wire.phase
        payload = copy.deepcopy(schedule_template)
        payload["requests"][0]["requested_by"]["display_name"] = (
            "workspace-b-schedule-owner" if phase.startswith("b") else "workspace-a-schedule-owner")
        return 200, payload
    def health():
        if unknown_health.is_set():
            return h.RawHttpResponse(503, b'{"error":"synthetic identity unread"}', content_type="application/json")
        return wire.health()
    def cancel(body):
        with wire.lock:
            phase = wire.phase
        cancel_requests.append((phase, json.loads(body)))
        return 200, {"status": "ok", "message": "synthetic schedule cancelled"}
    fixtures.update({ROSTER_PATH: wire.roster, "/health": health, "/health?full=1": health,
                     h.SCHEDULES_PATH: schedules,
                     "/api/v1/tools/masc_schedule_cancel": h.RequestHttpResponse(cancel)})
    requests = []
    def interact(process, fd, _slave, output, _base):
        h.resize_and_wait(process, fd, output,
            rows=45, columns=300, needle=b"MASC Dashboard",
            controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), label
        h.palette_go(process, fd, output, b"go schedules", b"reaction:matched_consumed_ack")
        h.send_and_wait(process, fd, output, b"x", b"armed: cancel schedule-proof-701")
        wire.publish("b")
        await_screen(lambda text: b"MISMATCH local " in text and b"armed: cancel" not in text
                     and b"reaction:matched_consumed_ack" in text,
                     "B identity did not withdraw A's cancel arm and apply its list")
        h.send_and_wait(process, fd, output, b"\x1b[C", b"workspace-b-schedule-owner")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Schedules")
        h.send_and_wait(process, fd, output, b"x", b"armed: cancel schedule-proof-701")
        assert cancel_requests == [], "A's first press authorized a POST on B"
        os.write(fd, b"x")
        assert h.wait_for_fixture_state(process, fd, output, lambda: len(cancel_requests) == 1,
            timeout=WAIT_SECONDS), "the explicit B confirmation did not send"
        assert cancel_requests[0][0] == "b" and cancel_requests[0][1]["schedule_id"] == "schedule-proof-701"
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Schedules")
        h.tab_until(process, fd, output, b"MASC Keepers")
        await_screen(lambda text: b"b.current" in text, "B roster was not applied")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"u", "Keepers ▸ alpha ▸ runtime".encode())
        wire.publish("a-returned")
        await_screen(lambda text: b"a.returned" in text and b"MASC Keepers" in text
                     and "▸ runtime".encode() not in text, "A identity did not close B runtime picker")
        unknown_health.set()
        # Health failure and a successful roster share this refresh. An
        # explicit lifecycle key must refuse even if that roster reports live.
        h.palette_go(process, fd, output, b"go System / runtime.toml", b"server identity unread")
        h.tab_until(process, fd, output, b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"w", b"Workspace identity has not been read; action unavailable")
        assert not [path for path, _ in requests if path.startswith("/api/v1/keepers/")], requests
        os.write(fd, b"q")
    h.run_terminal_scenario(binary,
        description="workspace switch withdraws schedule confirmation, runtime picker and unknown-identity lifecycle",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        http_requests=requests, refresh=0.5, terminal_cols=300)


def observer_workspace_retirement(binary: str) -> None:
    """A live old stream cannot carry its session, cursor or events into B."""
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    fixtures.update(h.observer_http_fixtures())
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    release_a = threading.Event()
    release_b = threading.Event()
    subscriptions = []
    sessions = []
    def initialize(body):
        request = json.loads(body)
        assert request["method"] == "initialize", request
        with wire.lock:
            phase = wire.phase
        session = "session-workspace-" + phase
        sessions.append(session)
        return h.RawHttpResponse(200, json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {}}).encode(),
            content_type="application/json", headers=(("Mcp-Session-Id", session),))
    def frame(event_id, tool):
        value = {"type": "keeper_tool_call", "name": "alpha", "tool_name": tool,
                 "ts_unix": 100.0, "turn": 7, "tool_use_id": tool,
                 "tool_args": {"workspace_probe": tool}, "tool_result": {"receipt": tool}}
        return f"id: {event_id}\ndata: ".encode() + json.dumps(value).encode() + b"\n\n"
    def observer(headers):
        with wire.lock:
            phase = wire.phase
        subscriptions.append((phase, headers))
        def chunks():
            if phase == "a":
                yield frame(41, "a-observer-visible")
                assert release_a.wait(timeout=30), "A observer fixture not released"
                yield frame(42, "a-observer-late-forbidden")
            else:
                yield frame(1, "b-observer-visible")
                assert release_b.wait(timeout=30), "B observer fixture not released"
                yield frame(2, "b-observer-settled")
        return h.StreamingHttpResponse(chunks, headers=(
            ("x-masc-sse-instance-id", "epoch-workspace-" + phase), ("x-masc-sse-replay", "fresh")))
    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health, "/health?full=1": wire.health,
                     "/mcp": h.RequestHttpResponse(initialize),
                     "/mcp?sse_kind=observer": h.HeadersHttpResponse(observer)})
    def interact(process, fd, _slave, output, _base):
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), label
        try:
            h.resize_and_wait(process, fd, output,
                rows=45, columns=300, needle=b"MASC Dashboard",
                controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            h.tab_until(process, fd, output, b"MASC System")
            h.send_and_wait(process, fd, output, b"A", b"MASC Activity")
            h.send_and_wait(process, fd, output, b"f", b"scope actions")
            await_screen(lambda text: b"a-observer-visible" in text, "A event was not applied")
            wire.publish("b")
            await_screen(lambda text: b"b-observer-visible" in text, "B fresh event was not applied")
            assert b"a-observer-visible" not in screen(output), "A acting projection survived B"
            b_headers = [headers for phase, headers in subscriptions if phase == "b"]
            assert b_headers and b_headers[0].get("mcp-session-id") == "session-workspace-b", subscriptions
            assert "last-event-id" not in b_headers[0] and "x-masc-sse-instance-id" not in b_headers[0], subscriptions
            assert "session-workspace-a" in sessions and "session-workspace-b" in sessions, sessions
            release_a.set()
            release_b.set()
            await_screen(lambda text: b"b-observer-settled" in text, "B completion barrier was not applied")
            assert b"a-observer-late-forbidden" not in screen(output)
            h.palette_go(process, fd, output, b"go dashboard", b"MASC Dashboard")
            os.write(fd, b"q")
        finally:
            release_a.set()
            release_b.set()
    h.run_terminal_scenario(binary,
        description="workspace switch retires live observer session, cursor and acting events",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        refresh=0.5, terminal_cols=300)


def identity_refresh_workspace_chain(binary: str) -> None:
    """Hold provider one's actual POST; withdrawal forbids provider two's POST."""
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    held_first = threading.Event()
    release_first = threading.Event()
    submitted = []
    first_held = False
    def providers():
        with wire.lock:
            phase = wire.phase
        return 200, {"providers": [
            {"provider": provider, "provider_label": f"{phase}-identity-{provider}",
             "tools": [], "also_on": [], "enabled": True}
            for provider in ("first", "second")]}
    def refresh(body):
        nonlocal first_held
        provider = json.loads(body)["provider"]
        with wire.lock:
            phase = wire.phase
            submitted.append((phase, provider))
        if not first_held:
            first_held = True
            assert provider == "first", submitted
            held_first.set()
            assert release_first.wait(timeout=30), "first identity POST fixture not released"
        return 200, {"status": "ok"}
    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health, "/health?full=1": wire.health,
        "/api/v1/keepers/oauth/attached-tools?keeper=alpha": providers,
        "/api/v1/keepers/alpha/identity-refresh": h.RequestHttpResponse(refresh)})
    def interact(process, fd, _slave, output, _base):
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), label
        def open_identity(marker):
            # The same marked title strip as keyboard [/] navigation; no
            # hardcoded index or tab count selects a different detail surface.
            title_rows = [row for row, text in h.screen_rows(bytes(output)).items()
                          if b"Info" in text and b"Identity" in text]
            assert len(title_rows) == 1, h.screen_rows(bytes(output))
            h.press_label_on_screen(process, fd, output, b"Identity", row=title_rows[0], needle=marker)
        try:
            h.resize_and_wait(process, fd, output,
                rows=45, columns=300, needle=b"MASC Dashboard",
                controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", b"Total Turns:")
            open_identity(b"a-identity-second")
            os.write(fd, b"R")
            assert h.wait_for_fixture_event(process, fd, output, held_first,
                timeout=WAIT_SECONDS), "first provider POST was not held"
            wire.publish("b")
            await_screen(lambda text: b"MISMATCH local " in text
                         and b"a-identity-first" not in text,
                         "B authority was not applied while first POST was held")
            open_identity(b"b-identity-second")
            assert b"a-identity-first" not in screen(output), "A Identity cache survived B"
            release_first.set()
            wire.publish("b-after-late")
            open_identity(b"b-after-late-identity-second")
            # The fresh B provider reading is a client-visible post-release
            # barrier. Server return events alone do not prove old callbacks
            # ran; per-request guards/cancellation are also source contracts.
            assert submitted == [("a", "first")], submitted
            wire.publish("a-returned")
            await_screen(lambda text: b"Base: " + wire.local_base.encode() in text
                         and b"MISMATCH" not in text,
                         "A identity was not restored in the current footer")
            open_identity(b"a-returned-identity-second")
            os.write(fd, b"R")
            assert h.wait_for_fixture_state(process, fd, output, lambda: len(submitted) == 3,
                timeout=WAIT_SECONDS), "fresh authorized provider refresh did not complete"
            assert submitted == [("a", "first"), ("a-returned", "first"),
                                 ("a-returned", "second")], submitted
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            release_first.set()
    h.run_terminal_scenario(binary,
        description="workspace withdrawal cancels held identity mutation before its next provider and allows fresh A retry",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        refresh=0.5, terminal_cols=300)



def bundle_identity_during_read(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    class BundleWire(WorkspaceWire):
        armed = False
        def roster(self):
            payload = super().roster()
            with self.lock:
                swap = self.armed
                self.armed = False
            if swap:
                self.publish("b")
                payload[1]["keepers"][0]["runtime_id"] = "cross-workspace-poison"
            return payload
    wire = BundleWire(fixtures[ROSTER_PATH][1])
    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
                     "/health?full=1": wire.health})
    def interact(process, fd, _slave, output, _base):
        h.resize_and_wait(process, fd, output,
            rows=34, columns=TERMINAL_COLUMNS, needle=b"MASC Dashboard",
            controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
        h.tab_until(process, fd, output, b"MASC Keepers")
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: b"a.current" in screen(output), timeout=WAIT_SECONDS)
        with wire.lock:
            wire.armed = True
        start = len(output)
        os.write(fd, b"r")
        def boundary_observed():
            with wire.lock:
                return any(e["event"] == "health" and e["phase"] == "b" for e in wire.events)
        assert h.wait_for_fixture_state(process, fd, output, boundary_observed,
            timeout=WAIT_SECONDS), "post-roster B identity was not probed"
        h.resize_and_wait(process, fd, output, rows=36, columns=TERMINAL_COLUMNS,
                         needle=b"MASC Keepers", controls=(h.FULL_REDRAW,))
        os.write(fd, b"r")
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: b"b.current" in screen(output) and b"MISMATCH local " in screen(output),
            timeout=WAIT_SECONDS), "a fresh coherent B bundle did not recover"
        assert b"cross-workspace-poison" not in h.CSI_RE.sub(b"", bytes(output[start:])), \
            "an A-started bundle displayed the B response before revalidation"
        os.write(fd, b"q")
    h.run_terminal_scenario(binary,
        description="discard a bundle whose workspace changes during its roster GET",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        refresh=30.0, terminal_cols=TERMINAL_COLUMNS)


def settings_editor_workspace_change(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
                     "/health?full=1": wire.health,
                     h.KEEPER_SETTINGS_PATH: h.keeper_settings_fixture()})
    posts: h.HttpRequests = []
    with tempfile.TemporaryDirectory(prefix="tui-workspace-editor-") as work:
        started, release = Path(work, "started"), Path(work, "release")
        editor = Path(work, "edit.py")
        editor.write_text("import json, sys, time\nfrom pathlib import Path\n"
            "path=Path(sys.argv[1]); value=json.loads(path.read_text())\n"
            "value['activation_mode']='autonomous'; path.write_text(json.dumps(value))\n"
            f"Path({str(started)!r}).touch()\n"
            f"while not Path({str(release)!r}).exists(): time.sleep(0.01)\n")
        def interact(process, fd, _slave, output, _base):
            try:
                h.resize_and_wait(process, fd, output,
                    rows=40, columns=TERMINAL_COLUMNS, needle=b"MASC Dashboard",
                    controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
                h.tab_until(process, fd, output, b"MASC Keepers")
                h.select_keeper_row(process, fd, output, b"alpha")
                os.write(fd, b"e")
                assert h.wait_for_fixture_state(process, fd, output, started.exists,
                    timeout=WAIT_SECONDS), "settings editor did not open"
                # The clone keeps the same keeper name and config revision.
                # No event-loop refresh can retire A while $EDITOR blocks.
                wire.publish("b")
                release.touch()
                assert h.wait_for_fixture_state(process, fd, output,
                    lambda: b"settings not saved" in screen(output), timeout=WAIT_SECONDS), \
                    "post-editor identity change was not visibly refused"
                assert not [p for p, _ in posts if p == h.KEEPER_SETTINGS_PATH], \
                    "the edited A patch was posted to same-revision B"
                os.write(fd, b"q")
            finally:
                release.touch()
        h.run_terminal_scenario(binary,
            description="same-revision workspace replacement during settings editor refuses the POST",
            interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
            http_requests=posts, extra_env={"EDITOR": shlex.join([sys.executable, str(editor)])},
            refresh=30.0, terminal_cols=TERMINAL_COLUMNS)


def ask_workspace_withdrawal(binary: str) -> None:
    # Exercise both the armed editor and an already admitted, held POST.
    for submit in (False, True):
        fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
        wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
        answer = h.GatedHttpResponse((200, {"ok": True}), hold_seconds=30.0)
        b_asks = threading.Event()
        def asks():
            with wire.lock:
                phase = wire.phase
                wire.events.append({"event": "asks", "phase": phase})
            if phase == "a":
                return h.keeper_asks_response()
            b_asks.set()
            return 503, {"error": "B questions unavailable"}
        fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
            "/health?full=1": wire.health, h.KEEPER_ASKS_PATH: asks,
            h.KEEPER_ASK_ANSWER_PATH: answer})
        posts: h.HttpRequests = []
        def interact(process, fd, _slave, output, _base):
            try:
                h.resize_and_wait(process, fd, output,
                    rows=40, columns=TERMINAL_COLUMNS, needle=b"MASC Dashboard",
                    controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
                h.palette_go(process, fd, output, b"go Approvals", b"Questions waiting on you")
                h.send_and_wait(process, fd, output, b"a", b"Enter:answer")
                h.send_and_wait(process, fd, output, b"1", b"1 (o) ")
                h.send_and_wait(process, fd, output, b"\r", b"Press Enter again to send")
                if submit:
                    os.write(fd, b"\r")
                    assert h.wait_for_fixture_event(process, fd, output, answer.requested,
                        timeout=WAIT_SECONDS), "Ask POST was not admitted by A"
                wire.publish("b")
                assert h.wait_for_fixture_state(process, fd, output,
                    lambda: b"MISMATCH local " in screen(output)
                        and b"ship the cold-start change now?" not in screen(output)
                        and b"Press Enter again to send" not in screen(output),
                    timeout=WAIT_SECONDS), "A question/editor/confirmation survived B failure"
                assert h.wait_for_fixture_event(process, fd, output, b_asks,
                    timeout=WAIT_SECONDS), "B failing asks read was not observed"
                h.palette_go(process, fd, output, b"go Keepers", b"MASC Keepers")
                answer.release.set()
                wire.publish("b-after-late")
                assert h.wait_for_fixture_state(process, fd, output,
                    lambda: b"b.settled" in screen(output), timeout=WAIT_SECONDS)
                # Full refreshes normally read asks. The cancelled answer
                # must never publish its old completion or recreate answer mode.
                h.palette_go(process, fd, output, b"go Approvals", b"MASC Approvals")
                assert b"Enter:answer" not in screen(output)
                assert b"ship the cold-start change now?" not in screen(output)
                assert len([p for p, _ in posts if p == h.KEEPER_ASK_ANSWER_PATH]) == int(submit)
                os.write(fd, b"q")
            finally:
                answer.release.set()
        h.run_terminal_scenario(binary,
            description=f"Ask editor and held submit are withdrawn with workspace (admitted={submit})",
            interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
            http_requests=posts, refresh=0.5, terminal_cols=TERMINAL_COLUMNS)


def github_workspace_withdrawal(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    release = threading.Event()
    def chunks():
        yield b'data: {"text":"A-device-code-visible"}\n\n'
        assert release.wait(timeout=30), "GitHub stream was not released"
        yield b'data: {"text":"A-late-device-code-forbidden"}\n\n'
    def identity():
        with wire.lock:
            phase = wire.phase
        return 200, {"hostname": "github.com", "effective": {
            "authenticated": True, "login": phase + "-github-current", "scopes": []}}
    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
        "/health?full=1": wire.health, "/api/v1/keepers/alpha/github-identity": identity,
        "/api/v1/keepers/alpha/github-login": h.StreamingHttpResponse(chunks)})
    posts: h.HttpRequests = []
    def interact(process, fd, _slave, output, _base):
        def await_screen(predicate):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS)
        try:
            h.resize_and_wait(process, fd, output,
                rows=45, columns=300, needle=b"MASC Dashboard",
                controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", b"Total Turns:")
            title_rows = [row for row, text in h.screen_rows(bytes(output)).items()
                          if b"Info" in text and b"GitHub" in text]
            assert len(title_rows) == 1
            h.press_label_on_screen(process, fd, output, b"GitHub", row=title_rows[0],
                                    needle=b"a-github-current")
            h.send_and_wait(process, fd, output, b"L", b"A-device-code-visible")
            wire.publish("b")
            await_screen(lambda text: b"MISMATCH local " in text and b"A-device-code-visible" not in text)
            boundary = len(output)
            release.set()
            wire.publish("b-after-late")
            # Re-entering obtains a fresh, stamped B observation after the
            # server released the stale stream; it cannot recreate A's view.
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            await_screen(lambda text: b"b.settled" in text)
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", b"GitHub")
            if b"Login scopes" not in screen(output):
                title_rows = [row for row, text in h.screen_rows(bytes(output)).items()
                              if b"Info" in text and b"GitHub" in text]
                assert len(title_rows) == 1
                h.press_label_on_screen(process, fd, output, b"GitHub", row=title_rows[0],
                                        needle=b"b-after-late-github-current")
            await_screen(lambda text: b"b-after-late-github-current" in text)
            assert b"A-late-device-code-forbidden" not in h.CSI_RE.sub(b"", bytes(output[boundary:]))
            assert len([p for p, _ in posts if p.startswith("/api/v1/keepers/alpha/github-login")]) == 1
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")
        finally:
            release.set()
    h.run_terminal_scenario(binary,
        description="GitHub device stream cannot restore a withdrawn workspace view",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        http_requests=posts, refresh=0.5, terminal_cols=300)


def connector_workspace_withdrawal(binary: str) -> None:
    """Same IDs cannot transfer confirmation or a held two-request write."""
    fixtures = h.connector_unbind_all_fixtures()
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    base_connectors = fixtures[h.CONNECTORS_PATH]
    submitted = []
    held = threading.Event()
    released = threading.Event()
    returned = threading.Event()
    def connectors():
        _, payload = base_connectors()
        with wire.lock:
            phase = wire.phase
        payload["connectors"][0]["display_name"] = phase + "-Discord"
        return 200, payload
    def unbind(body):
        with wire.lock:
            phase = wire.phase
            submitted.append((phase, json.loads(body)))
        if phase == "b" and len(submitted) == 1:
            held.set()
            assert released.wait(timeout=30), "held connector POST not released"
            returned.set()
        return 200, {"ok": True}
    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
        "/health?full=1": wire.health, h.CONNECTORS_PATH: connectors,
        h.CONNECTOR_UNBIND_PATH: h.RequestHttpResponse(unbind)})
    def interact(process, fd, _slave, output, _base):
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), label
        def open_channels(marker):
            title_rows = [row for row, text in h.screen_rows(bytes(output)).items()
                          if b"Info" in text and b"Channels" in text]
            assert len(title_rows) == 1, h.screen_rows(bytes(output))
            h.press_label_on_screen(process, fd, output, b"Channels", row=title_rows[0], needle=marker)
            await_screen(lambda text: marker in text and b"333 (name unknown)" in text,
                         "fresh connector targets are not visible")
        try:
            h.resize_and_wait(process, fd, output,
                rows=45, columns=300, needle=b"MASC Dashboard",
                controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", b"Total Turns:")
            open_channels(b"a-Discord")
            h.send_and_wait(process, fd, output, b"U", b"unbind all armed: press U again")
            assert submitted == [], submitted
            wire.publish("b")
            await_screen(lambda text: b"MISMATCH local " in text and b"a-Discord" not in text,
                         "workspace B did not withdraw A's connector projection")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            await_screen(lambda text: b"b.current" in text, "B roster not ready")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", b"Channels")
            open_channels(b"b-Discord")
            h.send_and_wait(process, fd, output, b"U", b"unbind all armed: press U again")
            assert submitted == [], "A's arm authorized B's first press"
            os.write(fd, b"U")
            assert h.wait_for_fixture_event(process, fd, output, held, timeout=WAIT_SECONDS)
            wire.publish("a-returned")
            await_screen(lambda text: b"MISMATCH" not in text and b"b-Discord" not in text,
                         "returning authority did not retire the held connector write")
            released.set()
            assert h.wait_for_fixture_event(process, fd, output, returned, timeout=WAIT_SECONDS)
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            await_screen(lambda text: b"a.returned" in text, "returned roster not ready")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", b"Channels")
            open_channels(b"a-returned-Discord")
            # A current successful read is the client response barrier. Only
            # B's already-admitted first request may exist; no successor POST.
            assert len(submitted) == 1 and submitted[0][0] == "b", submitted
            assert submitted[0][1] == {"channel_id": "111", "keeper_name": "alpha"}, submitted
            h.send_and_wait(process, fd, output, b"U", b"unbind all armed: press U again")
            assert len(submitted) == 1, "stale completion armed or dispatched on returned A"
            os.write(fd, b"q")
        finally:
            released.set()
    h.run_terminal_scenario(binary,
        description="workspace switch withdraws connector arms and held sequential writes with reused IDs",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        refresh=0.5, terminal_cols=300)


def tools_workspace_withdrawal(binary: str) -> None:
    fixtures = h.skills_usage_clarity_http_fixtures()
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    old_started, old_release, old_returned = (threading.Event() for _ in range(3))
    new_started, new_release = threading.Event(), threading.Event()
    counts = {"a": 0, "b": 0}

    def inventory(marker):
        return 200, {
            "tool_inventory": {"count": 0, "tools": []},
            "effective_keeper_surface": {
                "status": "available", "keeper_name": "alpha", "runtime_id": "fixture.tools",
                "official_client_kind": "agent_core", "tool_delivery": {"status": "delivered"},
                "native_posture": None, "skill_snapshot_revision": "c" * 64,
                "instruction_skills": [], "composition_skills": [], "skill_profiles": [],
                "skill_discovery_bytes": 0, "skill_eager_body_bytes": 0, "skills_left_out": [],
                "unavailable_skill_names": [], "count": 1,
                "tools": [{"name": marker, "origin": {"kind": "descriptor"}}],
                "tool_surface_sha256": None,
            },
            "skill_activations": {"status": "no_session", "keeper_name": "alpha"},
        }

    def tools():
        with wire.lock:
            phase = wire.phase
            counts[phase] += 1
            ordinal = counts[phase]
        if phase == "a" and ordinal > 1:
            old_started.set()
            assert old_release.wait(timeout=30), "old Tools fixture not released"
            old_returned.set()
            return inventory("workspace_a_late_forbidden")
        if phase == "b":
            new_started.set()
            assert new_release.wait(timeout=30), "new Tools fixture not released"
            return inventory("workspace_b_current_tools")
        return inventory("workspace_a_initial_tools")

    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health, "/health?full=1": wire.health,
        "/api/v1/dashboard/tools?keeper=alpha": tools, "/api/v1/dashboard/tools": tools})

    def interact(process, fd, _slave, output, _base):
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), label
        try:
            h.tab_until(process, fd, output, b"MASC System")
            h.send_and_wait(process, fd, output, b"t", b"workspace_a_initial_tools")
            assert h.wait_for_fixture_event(process, fd, output, old_started, timeout=WAIT_SECONDS)
            wire.publish("b")
            await_screen(lambda text: b"MISMATCH local " in text, "B authority did not become current")
            assert b"workspace_a_initial_tools" not in screen(output), "old cached inventory survived withdrawal"
            assert h.wait_for_fixture_event(process, fd, output, new_started, timeout=WAIT_SECONDS), "old pending slot blocked B read"
            new_release.set()
            await_screen(lambda text: b"workspace_b_current_tools" in text, "current B inventory did not load")
            old_release.set()
            assert h.wait_for_fixture_event(process, fd, output, old_returned, timeout=WAIT_SECONDS)
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: counts["b"] >= 2, timeout=WAIT_SECONDS), "current polling did not resume"
            h.drain_until_quiet(process, fd, output)
            visible = screen(output)
            assert b"workspace_b_current_tools" in visible and b"workspace_a_late_forbidden" not in visible, visible
            os.write(fd, b"q")
        finally:
            old_release.set()
            new_release.set()
    h.run_terminal_scenario(binary,
        description="Tools workspace withdrawal clears cached inventory and supersedes held same-Keeper reads",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        refresh=0.5, terminal_cols=300)


def verification_workspace_withdrawal(binary: str) -> None:
    """Held A rows cannot restore an approval arm on B with the same IDs."""
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    fixtures.update(h.verification_verdict_fixtures())
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    old_started = threading.Event()
    old_release = threading.Event()
    old_returned = threading.Event()
    hold_next = False
    verdicts = []

    def queue():
        nonlocal hold_next
        with wire.lock:
            phase = wire.phase
            held = hold_next and phase == "a"
            if held:
                hold_next = False
        if held:
            old_started.set()
            assert old_release.wait(timeout=30), "A verification fixture not released"
            old_returned.set()
        if phase == "b":
            return 503, {"error": "verification-b-not-ready"}
        row = h.verification_request_row("task-901")
        row["task_title"] = (
            "workspace-a-verification-row" if phase == "a"
            else "workspace-b-verification-row")
        return 200, h.verification_snapshot([row])

    def verdict(body):
        with wire.lock:
            phase = wire.phase
        verdicts.append((phase, json.loads(body)))
        return 200, {"ok": True, "message": "workspace verdict recorded", "noop": False}

    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
                     "/health?full=1": wire.health,
                     h.VERIFICATION_QUEUE_PATH: queue,
                     h.VERIFICATION_VERDICT_PATH: h.RequestHttpResponse(verdict)})

    def interact(process, fd, _slave, output, _base):
        nonlocal hold_next
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), label
        try:
            h.resize_and_wait(process, fd, output, rows=45, columns=300,
                needle=b"MASC Dashboard", controls=(h.FULL_REDRAW,))
            h.tab_until(process, fd, output, b"MASC Work")
            h.send_and_wait(process, fd, output, b"v", b"Task Review")
            await_screen(lambda text: b"workspace-a-verification-row" in text,
                         "A verification row not visible")
            h.send_and_wait(process, fd, output, b"a",
                b"armed: approve task-901 -- same key again to send")
            assert verdicts == [], "first A press sent a verdict"
            with wire.lock:
                hold_next = True
            assert h.wait_for_fixture_event(process, fd, output, old_started,
                timeout=WAIT_SECONDS), "next A verification read was not held"
            wire.publish("b")
            await_screen(lambda text: b"MISMATCH local " in text
                         and b"workspace-a-verification-row" not in text
                         and b"armed: approve" not in text,
                         "B did not withdraw A verification rows and confirmation")
            os.write(fd, b"a")
            old_release.set()
            assert h.wait_for_fixture_event(process, fd, output, old_returned,
                timeout=WAIT_SECONDS), "A verification reply was not released"
            await_screen(lambda text: b"verification-b-not-ready" in text,
                         "fresh B verification refusal did not settle")
            assert verdicts == [], "A confirmation sent a verdict in B"
            wire.publish("b-after-late")
            await_screen(lambda text: b"workspace-b-verification-row" in text,
                         "B verification read did not recover")
            assert b"workspace-a-verification-row" not in screen(output)
            h.send_and_wait(process, fd, output, b"a",
                b"armed: approve task-901 -- same key again to send")
            assert verdicts == [], "B reused A confirmation for matching IDs"
            os.write(fd, b"a")
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: len(verdicts) == 1, timeout=WAIT_SECONDS)
            assert verdicts[0] == ("b-after-late", {
                "task_id": "task-901", "verification_id": "vr-task-901",
                "verdict": "approve"}), verdicts
            os.write(fd, b"q")
        finally:
            old_release.set()
    h.run_terminal_scenario(binary,
        description="workspace verification withdrawal requires fresh rows and confirmation",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        refresh=0.5, terminal_cols=300)


def task_dispatch_workspace_withdrawal(binary: str) -> None:
    """An A MCP initialization cannot create a task after B becomes current."""
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    initialized = threading.Event()
    release_initialize = threading.Event()
    initialize_returned = threading.Event()
    created = []
    requests = []
    foreground_armed = threading.Event()
    observer_requested, observer_release = hold_observer_before_headers(fixtures)

    def mcp(body):
        request = json.loads(body)
        with wire.lock:
            phase = wire.phase
            held = phase == "a" and foreground_armed.is_set()
            if request["method"] == "initialize" and held:
                foreground_armed.clear()
        if request["method"] == "initialize":
            if held:
                initialized.set()
                assert release_initialize.wait(timeout=30), "A initialization not released"
                initialize_returned.set()
            return h.RawHttpResponse(200, json.dumps({
                "jsonrpc": "2.0", "id": request["id"], "result": {}}).encode(),
                content_type="application/json",
                headers=(("Mcp-Session-Id", "task-session-" + phase),))
        assert request["method"] == "tools/call", request
        assert request["params"]["name"] == "masc_add_task", request
        created.append((phase, request["params"]["arguments"]))
        return 200, {"jsonrpc": "2.0", "id": request["id"], "result": {
            "content": [{"type": "text", "text": json.dumps({
                "ok": True, "task_id": "task-9"})}], "isError": False}}

    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
                     "/health?full=1": wire.health,
                     HISTORY_PATH: wire.history, MEMORY_PATH: wire.memory,
                     "/mcp": h.RequestHttpResponse(mcp),
                     "/api/v1/keepers/chat/stream": (503, {"error": "synthetic chat capture"})})

    def interact(process, fd, _slave, output, _base):
        def await_screen(predicate, label):
            assert h.wait_for_fixture_state(process, fd, output,
                lambda: predicate(screen(output)), timeout=WAIT_SECONDS), label
        try:
            assert h.wait_for_fixture_event(process, fd, output, observer_requested,
                timeout=WAIT_SECONDS), "startup observer did not finish initialization"
            assert not initialized.is_set(), "startup initialization satisfied the task barrier"
            h.resize_and_wait(process, fd, output, rows=45, columns=300,
                needle=b"MASC Dashboard", controls=(h.FULL_REDRAW,))
            h.tab_until(process, fd, output, b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ alpha ▸ chat".encode())
            h.send_and_wait(process, fd, output, b"/task workspace-a-pending-task",
                h.composer_showing(b"/task workspace-a-pending-task"))
            foreground_armed.set()
            h.send_and_wait(process, fd, output, b"\r",
                b"creating a task for alpha: workspace-a-pending-task")
            assert h.wait_for_fixture_event(process, fd, output, initialized,
                timeout=WAIT_SECONDS), "A task initialization not held"
            wire.publish("b")
            await_screen(lambda text: b"MISMATCH local " in text and b"b.current" in text,
                         "B authority not applied while initialization held")
            release_initialize.set()
            assert h.wait_for_fixture_event(process, fd, output, initialize_returned,
                timeout=WAIT_SECONDS), "A initialization response not released"
            wire.publish("b-after-late")
            await_screen(lambda text: b"b.settled" in text, "B refresh not applied")
            assert created == [], "A initialization created work in B"
            assert b"workspace-a-pending-task" not in screen(output), "A dispatch revived its draft"
            assert not [path for path, _ in requests if path == "/api/v1/keepers/chat/stream"], requests
            wire.publish("a-returned")
            await_screen(lambda text: b"a.returned" in text and b"MISMATCH" not in text,
                         "A authority did not return")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"m", "Keepers ▸ alpha ▸ chat".encode())
            h.send_and_wait(process, fd, output, b"/task workspace-a-fresh-task",
                h.composer_showing(b"/task workspace-a-fresh-task"))
            os.write(fd, b"\r")
            chat = h.wait_for_http_request(process, fd, output, requests,
                path="/api/v1/keepers/chat/stream")
            assert created == [("a-returned", {"title": "workspace-a-fresh-task"})], created
            assert json.loads(chat)["message"] == "[task-9] workspace-a-fresh-task"
            os.write(fd, b"q")
        finally:
            release_initialize.set()
            observer_release.set()
    h.run_terminal_scenario(binary,
        description="workspace withdrawal cancels pending task creation and permits a fresh task after return",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        http_requests=requests, refresh=0.5, terminal_cols=300)


def hold_observer_before_headers(fixtures):
    """Observe completed startup initialization without caching its session.

    The observer GET proves its initialize returned. Withhold response headers
    so Observer_opened cannot run and Observer_opening cannot retry, leaving
    the foreground operation as the only possible next A initialization.
    """
    requested, release = threading.Event(), threading.Event()

    def observer(_headers):
        requested.set()
        assert release.wait(timeout=30), "baseline observer was not released"
        return h.RawHttpResponse(503, b'{"error":"baseline observer stopped"}',
            content_type="application/json")

    fixtures["/mcp?sse_kind=observer"] = h.HeadersHttpResponse(observer)
    return requested, release


def resource_workspace_withdrawal(binary: str) -> None:
    for held_method in ("initialize", "resources/read"):
        fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
        wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
        started, release, returned = (threading.Event() for _ in range(3))
        foreground_armed = threading.Event()
        observer_requested, observer_release = hold_observer_before_headers(fixtures)
        calls = []
        uri = "masc://same-resource.txt"

        def mcp(body):
            request = json.loads(body)
            method = request["method"]
            with wire.lock:
                phase = wire.phase
                held = phase == "a" and method == held_method and foreground_armed.is_set()
                if held:
                    foreground_armed.clear()
            calls.append((phase, method))
            if held:
                started.set()
                assert release.wait(timeout=30), "held resource request was not released"
                returned.set()
            headers = ()
            if method == "initialize":
                result = {}
                headers = (("Mcp-Session-Id", "resource-session-" + phase),)
            elif method == "resources/list":
                result = {"resources": [{"uri": uri, "name": "resource-" + phase,
                    "mimeType": "text/plain"}]}
            elif method == "resources/read":
                result = {"contents": [{"uri": uri, "mimeType": "text/plain",
                    "text": "resource-body-" + phase}]}
            else:
                raise AssertionError(request)
            return h.RawHttpResponse(200,
                json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}).encode(),
                content_type="application/json", headers=headers)

        fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
            "/health?full=1": wire.health, "/mcp": h.RequestHttpResponse(mcp)})

        def interact(process, fd, _slave, output, _base):
            try:
                assert h.wait_for_fixture_event(process, fd, output, observer_requested,
                    timeout=WAIT_SECONDS), "startup observer did not finish initialization"
                assert not started.is_set(), "startup initialization satisfied the foreground barrier"
                h.tab_until(process, fd, output, b"MASC System")
                if held_method == "initialize":
                    foreground_armed.set()
                h.send_and_wait(process, fd, output, b"s", b"MASC System / Resources")
                if held_method == "resources/read":
                    h.wait_for_output(process, fd, output, b"resource-a", start=0, timeout=WAIT_SECONDS)
                    foreground_armed.set()
                    os.write(fd, b"\r")
                assert h.wait_for_fixture_event(process, fd, output, started, timeout=WAIT_SECONDS)
                wire.publish("b")
                assert h.wait_for_fixture_state(process, fd, output,
                    lambda: b"MISMATCH local " in screen(output), timeout=WAIT_SECONDS)
                assert b"resource-a" not in screen(output) and b"resource-body-a" not in screen(output)
                release.set()
                assert h.wait_for_fixture_event(process, fd, output, returned, timeout=WAIT_SECONDS)
                h.send_and_wait(process, fd, output, b"r", b"resource-b")
                h.send_and_wait(process, fd, output, b"\r", b"resource-body-b")
                assert b"resource-body-a" not in screen(output), screen(output)
                if held_method == "initialize":
                    assert [(phase, method) for phase, method in calls
                            if method == "resources/list"] == [("b", "resources/list")], calls
                os.write(fd, b"q")
            finally:
                release.set()
                observer_release.set()
        h.run_terminal_scenario(binary,
            description=f"Resource {held_method} ownership is withdrawn before same-URI B recovery",
            interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
            refresh=0.5, terminal_cols=300)



def runtime_parameter_workspace_withdrawal(binary: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures(alpha_runtime_id="a.current")
    wire = WorkspaceWire(fixtures[ROSTER_PATH][1])
    current_read = threading.Event()
    writes = []

    def parameters():
        with wire.lock:
            phase = wire.phase
        if phase != "a":
            current_read.set()
            return 503, {"error": "B parameters unavailable"}
        return 200, {"parameters": [{"key": "original_a_parameter", "current": 7,
            "default": 1, "has_override": True, "meta": {"value_type": "int"}}]}

    def write(body):
        writes.append(json.loads(body))
        return 200, {"ok": True}

    fixtures.update({ROSTER_PATH: wire.roster, "/health": wire.health,
        "/health?full=1": wire.health, "/api/v1/runtime/params": parameters,
        "/api/v1/runtime/params/set": h.RequestHttpResponse(write),
        "/api/v1/runtime/params/clear": h.RequestHttpResponse(write)})

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", b"Keepers")
        h.send_and_wait(process, fd, output, b"c", b"Esc:detail")
        h.send_and_wait(process, fd, output, b"/settings", b"/settings")
        h.send_and_wait(process, fd, output, b"\r", b"original_a_parameter")
        h.send_and_wait(process, fd, output, b"\r", b"editing original_a_parameter")
        wire.publish("b")
        assert h.wait_for_fixture_state(process, fd, output,
            lambda: b"MISMATCH local " in screen(output), timeout=WAIT_SECONDS)
        assert b"original_a_parameter" not in screen(output), screen(output)
        os.write(fd, b"\r")
        # Re-read B explicitly. Its failure cannot authorize retained A input.
        os.write(fd, b"r")
        assert h.wait_for_fixture_event(process, fd, output, current_read, timeout=WAIT_SECONDS)
        h.drain_until_quiet(process, fd, output)
        assert writes == [], "parameters sent an A-derived write after withdrawal"
        os.write(fd, b"q")
    h.run_terminal_scenario(binary,
        description="Workspace withdrawal retires parameter edits before successor writes",
        interact=interact, prepare_workspace=wire.prepare, http_fixtures=fixtures,
        refresh=0.5, terminal_cols=300)


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
    task_dispatch_workspace_withdrawal(binary)
    verification_workspace_withdrawal(binary)
    tools_workspace_withdrawal(binary)
    resource_workspace_withdrawal(binary)
    runtime_parameter_workspace_withdrawal(binary)
    connector_workspace_withdrawal(binary)
    bundle_identity_during_read(binary)
    settings_editor_workspace_change(binary)
    ask_workspace_withdrawal(binary)
    github_workspace_withdrawal(binary)
    run(binary, captures)
    queued_workspace_inputs(binary)
    queued_workspace_inputs(binary, root_only=True)
    scoped_roster_authority(binary)
    staged_payload_workspace_inputs(binary)
    staged_payload_workspace_inputs(binary, root_only=True)
    armed_schedule_and_runtime_workspace(binary)
    observer_workspace_retirement(binary)
    identity_refresh_workspace_chain(binary)
    print("remote workspace history: PASS (held response withdrawal and unsent draft retention)")
